#!/usr/bin/env python3
import sys
import os
import shutil
from multiprocessing import Pool

# 工作子进程逻辑：处理被分配的一组 txt 文件
def worker_process(file_list, id_start, id_end):
    latencies = []
    for filepath in file_list:
        start_ts = None
        with open(filepath, 'r') as f:
            for line in f:
                parts = line.split()
                try:
                    # 定位 raw 格式中的 type: 关键字
                    type_idx = parts.index("type:")
                    ts = int(parts[type_idx - 1]) # type: ignore
                    event_id = parts[type_idx + 1]

                    if event_id == id_start:
                        start_ts = ts
                    elif event_id == id_end and start_ts is not None:
                        diff = ts - start_ts
                        if diff >= 0:
                            latencies.append(diff)
                        start_ts = None # 消费掉起点的 ts
                except ValueError:
                    continue
    return latencies

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("参数错误: 需要 raw_log, id_start, id_end")
        sys.exit(1)

    raw_log = sys.argv[1]
    id_start = sys.argv[2]
    id_end = sys.argv[3]

    # 1. 创建存放中间结果的文件夹 (加上 PID 防止多次运行冲突)
    tmp_dir = f"/tmp/ftrace_pids_dir_{os.getpid()}"
    if os.path.exists(tmp_dir):
        shutil.rmtree(tmp_dir)
    os.makedirs(tmp_dir)

    # 2. 遍历 raw log，按进程号分发记录到内存字典
    pid_data = {}
    with open(raw_log, 'r') as f:
        for line in f:
            parts = line.split()
            if "type:" in parts:
                pid = parts[0]
                if pid not in pid_data:
                    pid_data[pid] = []
                pid_data[pid].append(line)

    # 3. 将每个进程的记录落盘到独立的 txt 文件中
    files = []
    for pid, lines in pid_data.items():
        fpath = os.path.join(tmp_dir, f"{pid}.txt")
        with open(fpath, 'w') as f:
            f.writelines(lines)
        files.append(fpath)

    total_pids = len(files)
    if total_pids == 0:
        print("\n[警告] 未找到任何有效的跟踪记录。")
        sys.exit(0)

    # 4. 将所有 txt 文件平均分配给 16 组
    num_workers = min(16, total_pids) 
    chunks = [[] for _ in range(num_workers)]
    for i, fpath in enumerate(files):
        chunks[i % num_workers].append(fpath)

    # 5. 创建多进程进行时延计算
    pool = Pool(processes=num_workers)
    tasks = [(chunk, id_start, id_end) for chunk in chunks if chunk]
    
    # 阻塞等待所有进程池执行完成
    results = pool.starmap(worker_process, tasks)
    pool.close()
    pool.join()

    # 6. 将所有进程的数据合并
    all_latencies = []
    for res_list in results:
        all_latencies.extend(res_list)

    count = len(all_latencies)
    if count == 0:
        print("\n[警告] 未找到匹配的事件对样本。请确认探针在此期间被成功触发。")
        print(f"👉 中间结果文件已保留在: {tmp_dir}")
        sys.exit(0)

    # 7. 计算统计学分位数
    all_latencies.sort()
    total_sum = sum(all_latencies)
    avg = total_sum / count
    min_val = all_latencies[0]
    max_val = all_latencies[-1]

    def get_percentile(p):
        idx = int(count * p)
        if idx == 0: return all_latencies[0]
        if idx >= count: return all_latencies[-1]
        return all_latencies[idx]

    print(f"\n=== 最终结果 (16 核并发引擎 | 纯物理纳秒延迟) ===")
    print(f"参与计算的进程数: {total_pids} 个")
    print(f"有效样本总数: {count} 次\n")
    print("--- 统计摘要 ---")
    print(f"平均值 (Avg): {avg:.2f} ns")
    print(f"最小值 (Min): {min_val:.2f} ns")
    print(f"最大值 (Max): {max_val:.2f} ns\n")
    print("--- 分位数分布 (Percentiles) ---")
    print(f"P50 (中位数): {get_percentile(0.50):.2f} ns")
    print(f"P90 (90分位): {get_percentile(0.90):.2f} ns")
    print(f"P95 (95分位): {get_percentile(0.95):.2f} ns")
    print(f"P99 (99分位): {get_percentile(0.99):.2f} ns")

    # 任务结束，打印中间文件保存位置 (已移除 shutil.rmtree 删除操作)
    print(f"\n📁 [保留中间结果] ftrace 按 PID 拆分的文件保存在: {tmp_dir}")