import matplotlib.pyplot as plt
import numpy as np
import re

def extract_hardware_metrics(file_path):
    """Extract performance metrics from hardware output file"""
    with open(file_path, 'r') as f:
        content = f.read()
    
    metrics = {}
    
    # Extract p95 and p99 latency in microseconds
    p95_match = re.search(r'95th Percentile \(p95\):\s+(\d+\.?\d*)\s+us', content)
    p99_match = re.search(r'99th Percentile \(p99\):\s+(\d+\.?\d*)\s+us', content)
    
    if p95_match:
        metrics['p95_latency_us'] = float(p95_match.group(1))
    if p99_match:
        metrics['p99_latency_us'] = float(p99_match.group(1))
    
    # Extract IOPS
    iops_match = re.search(r'Estimated IOPS:\s+(\d+)', content)
    if iops_match:
        metrics['iops'] = float(iops_match.group(1))
    
    # Extract throughput (convert to MB/s for comparison)
    throughput_match = re.search(r'Average Throughput:\s+(\d+\.?\d*)\s+GB/s', content)
    if throughput_match:
        metrics['throughput_gbps'] = float(throughput_match.group(1))
        metrics['throughput_mbps'] = metrics['throughput_gbps'] * 1024  # Convert to MB/s
    
    # Extract average latency for speedup calculation
    avg_latency_match = re.search(r'Average Latency:\s+(\d+\.?\d*)\s+us', content)
    if avg_latency_match:
        metrics['avg_latency_us'] = float(avg_latency_match.group(1))
    
    return metrics

def extract_software_metrics(file_path):
    """Extract performance metrics from software output file"""
    with open(file_path, 'r') as f:
        content = f.read()
    
    metrics = {}
    
    # Extract p95 and p99 latency in microseconds
    p95_match = re.search(r'P95:\s+(\d+\.?\d*)\s+us', content)
    p99_match = re.search(r'P99:\s+(\d+\.?\d*)\s+us', content)
    
    if p95_match:
        metrics['p95_latency_us'] = float(p95_match.group(1))
    if p99_match:
        metrics['p99_latency_us'] = float(p99_match.group(1))
    
    # Extract average IOPS
    iops_match = re.search(r'Average IOPS:\s+(\d+\.?\d*)', content)
    if iops_match:
        metrics['iops'] = float(iops_match.group(1))
    
    # Extract average throughput (MB/s)
    throughput_match = re.search(r'Average Throughput:\s+(\d+\.?\d*)\s+MB/s', content)
    if throughput_match:
        metrics['throughput_mbps'] = float(throughput_match.group(1))
        metrics['throughput_gbps'] = metrics['throughput_mbps'] / 1024  # Convert to GB/s
    
    # Extract average latency
    avg_latency_match = re.search(r'Average latency:\s+(\d+\.?\d*)\s+us', content)
    if avg_latency_match:
        metrics['avg_latency_us'] = float(avg_latency_match.group(1))
    
    # Extract P50 latency for burst comparison
    p50_match = re.search(r'P50 \(median\):\s+(\d+\.?\d*)\s+us', content)
    if p50_match:
        metrics['p50_latency_us'] = float(p50_match.group(1))
    
    # Extract max latency
    max_latency_match = re.search(r'Max:\s+(\d+\.?\d*)\s+us', content)
    if max_latency_match:
        metrics['max_latency_us'] = float(max_latency_match.group(1))
    
    # Extract hardware accelerator speedup
    speedup_match = re.search(r'Hardware accelerator is\s+(\d+\.?\d*)x faster', content)
    if speedup_match:
        metrics['hw_accel_speedup'] = float(speedup_match.group(1))
    
    return metrics

def calculate_improvements(hardware_metrics, software_metrics):
    """Calculate improvement percentages and speedup factors"""
    improvements = {}
    
    # For latency: lower is better, so calculate % reduction
    improvements['p95_reduction'] = ((software_metrics['p95_latency_us'] - hardware_metrics['p95_latency_us']) / 
                                     software_metrics['p95_latency_us'] * 100)
    improvements['p99_reduction'] = ((software_metrics['p99_latency_us'] - hardware_metrics['p99_latency_us']) / 
                                     software_metrics['p99_latency_us'] * 100)
    improvements['avg_reduction'] = ((software_metrics['avg_latency_us'] - hardware_metrics['avg_latency_us']) / 
                                     software_metrics['avg_latency_us'] * 100)
    
    # For IOPS and throughput: higher is better, so calculate % increase
    improvements['iops_increase'] = ((hardware_metrics['iops'] - software_metrics['iops']) / 
                                     software_metrics['iops'] * 100)
    improvements['throughput_increase'] = ((hardware_metrics['throughput_mbps'] - software_metrics['throughput_mbps']) / 
                                           software_metrics['throughput_mbps'] * 100)
    
    # Calculate speedup (software latency / hardware latency)
    improvements['speedup_p95'] = software_metrics['p95_latency_us'] / hardware_metrics['p95_latency_us']
    improvements['speedup_p99'] = software_metrics['p99_latency_us'] / hardware_metrics['p99_latency_us']
    improvements['speedup_avg'] = software_metrics['avg_latency_us'] / hardware_metrics['avg_latency_us']
    improvements['speedup_iops'] = hardware_metrics['iops'] / software_metrics['iops']
    improvements['speedup_throughput'] = hardware_metrics['throughput_mbps'] / software_metrics['throughput_mbps']
    
    # Add max latency comparison
    if 'max_latency_us' in software_metrics:
        improvements['max_reduction'] = 100 - (hardware_metrics['p99_latency_us'] / software_metrics['max_latency_us'] * 100)
    
    return improvements

def create_latency_comparison_chart(hardware_metrics, software_metrics):
    """Create chart comparing latency metrics"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    
    # Chart 1: Main latency metrics
    metrics = ['p95 Latency', 'p99 Latency', 'Avg Latency']
    hardware_values = [
        hardware_metrics['p95_latency_us'],
        hardware_metrics['p99_latency_us'],
        hardware_metrics['avg_latency_us']
    ]
    software_values = [
        software_metrics['p95_latency_us'],
        software_metrics['p99_latency_us'],
        software_metrics['avg_latency_us']
    ]
    
    x = np.arange(len(metrics))
    width = 0.35
    
    bars1 = ax1.bar(x - width/2, hardware_values, width, label='Hardware', color='#2E86AB')
    bars2 = ax1.bar(x + width/2, software_values, width, label='Software', color='#A23B72')
    
    ax1.set_xlabel('Latency Metric', fontsize=12)
    ax1.set_ylabel('Latency (microseconds)', fontsize=12)
    ax1.set_title('Latency Comparison (Log Scale)', fontsize=14, fontweight='bold')
    ax1.set_xticks(x)
    ax1.set_xticklabels(metrics)
    ax1.set_yscale('log')  # Log scale due to huge differences
    ax1.legend()
    ax1.grid(True, alpha=0.3, linestyle='--', which='both')
    
    # Add value labels on bars
    for bars in [bars1, bars2]:
        for bar in bars:
            height = bar.get_height()
            ax1.annotate(f'{height:.2f}',
                       xy=(bar.get_x() + bar.get_width() / 2, height),
                       xytext=(0, 3),
                       textcoords="offset points",
                       ha='center', va='bottom', fontsize=9)
    
    # Chart 2: Latency distribution comparison
    latency_points = ['P50', 'P95', 'P99', 'Max']
    hw_latencies = [
        hardware_metrics['avg_latency_us'],  # Use avg as P50 approximation
        hardware_metrics['p95_latency_us'],
        hardware_metrics['p99_latency_us'],
        hardware_metrics['p99_latency_us']  # Hardware max is similar to P99
    ]
    sw_latencies = [
        software_metrics.get('p50_latency_us', software_metrics['avg_latency_us']),
        software_metrics['p95_latency_us'],
        software_metrics['p99_latency_us'],
        software_metrics.get('max_latency_us', software_metrics['p99_latency_us'])
    ]
    
    ax2.plot(latency_points, hw_latencies, marker='o', linewidth=2, label='Hardware', color='#2E86AB')
    ax2.plot(latency_points, sw_latencies, marker='s', linewidth=2, label='Software', color='#A23B72')
    ax2.fill_between(latency_points, hw_latencies, alpha=0.2, color='#2E86AB')
    ax2.fill_between(latency_points, sw_latencies, alpha=0.2, color='#A23B72')
    
    ax2.set_xlabel('Percentile', fontsize=12)
    ax2.set_ylabel('Latency (μs)', fontsize=12)
    ax2.set_title('Latency Distribution Comparison', fontsize=14, fontweight='bold')
    ax2.set_yscale('log')
    ax2.legend()
    ax2.grid(True, alpha=0.3, linestyle='--')
    
    # Add value annotations
    for i, (hw, sw) in enumerate(zip(hw_latencies, sw_latencies)):
        ax2.annotate(f'{hw:.1f}', xy=(i, hw), xytext=(0, 5), 
                    textcoords="offset points", ha='center', fontsize=9, color='#2E86AB')
        ax2.annotate(f'{sw:.1f}', xy=(i, sw), xytext=(0, -15), 
                    textcoords="offset points", ha='center', fontsize=9, color='#A23B72')
    
    plt.tight_layout()
    return fig

def create_performance_comparison_chart(hardware_metrics, software_metrics):
    """Create chart comparing IOPS and throughput"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    
    # Chart 1: IOPS comparison (log scale due to huge difference)
    labels = ['Hardware', 'Software']
    iops_values = [hardware_metrics['iops'], software_metrics['iops']]
    
    bars1 = ax1.bar(labels, iops_values, color=['#2E86AB', '#A23B72'])
    ax1.set_ylabel('IOPS', fontsize=12)
    ax1.set_title('IOPS Comparison (Log Scale)', fontsize=14, fontweight='bold')
    ax1.set_yscale('log')
    ax1.grid(True, alpha=0.3, linestyle='--', which='both')
    
    # Add value labels with formatting
    for bar in bars1:
        height = bar.get_height()
        if height > 1e6:
            label = f'{height/1e6:.1f}M'
        elif height > 1e3:
            label = f'{height/1e3:.1f}K'
        else:
            label = f'{height:.0f}'
        ax1.annotate(label,
                    xy=(bar.get_x() + bar.get_width() / 2, height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    # Chart 2: Throughput comparison (now with log scale)
    throughput_values_mbps = [hardware_metrics['throughput_mbps'], software_metrics['throughput_mbps']]
    
    bars2 = ax2.bar(labels, throughput_values_mbps, color=['#2E86AB', '#A23B72'])
    ax2.set_ylabel('Throughput (MB/s)', fontsize=12)
    ax2.set_title('Throughput Comparison (Log Scale)', fontsize=14, fontweight='bold')
    ax2.set_yscale('log')  # Changed to log scale
    ax2.grid(True, alpha=0.3, linestyle='--', which='both')
    
    # Add value labels
    for bar in bars2:
        height = bar.get_height()
        if height > 1000:
            label = f'{height/1000:.1f} GB/s'
        else:
            label = f'{height:.1f} MB/s'
        ax2.annotate(label,
                    xy=(bar.get_x() + bar.get_width() / 2, height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    plt.tight_layout()
    return fig

def create_improvement_percentage_chart(improvements):
    """Create chart showing percentage improvements"""
    fig, ax = plt.subplots(figsize=(12, 7))
    
    metrics = ['p95 Latency\nReduction', 'p99 Latency\nReduction', 'Avg Latency\nReduction', 
               'IOPS Increase', 'Throughput\nIncrease']
    values = [
        improvements['p95_reduction'],
        improvements['p99_reduction'],
        improvements['avg_reduction'],
        improvements['iops_increase'],
        improvements['throughput_increase']
    ]
    
    # Color coding: green for positive improvements
    colors = ['#18A558' if val >= 0 else '#E63946' for val in values]
    
    bars = ax.bar(metrics, values, color=colors, edgecolor='black', linewidth=1.5)
    ax.set_ylabel('Improvement (%)', fontsize=12, fontweight='bold')
    ax.set_title('Hardware Improvement Over Software (Log Scale)', fontsize=16, fontweight='bold')
    ax.axhline(y=0, color='black', linewidth=1.5, linestyle='-')
    
    # Set y-axis to log scale
    ax.set_yscale('log')
    
    # Adjust log scale to handle negative values by using symmetric log
    # Find the maximum absolute value for setting scale
    max_abs_value = max(abs(v) for v in values)
    if max_abs_value > 0:
        ax.set_ylim(bottom=10**(-1), top=10**(np.ceil(np.log10(max_abs_value)) + 0.5))
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y', which='both')
    
    # Add value labels with improved formatting
    for bar in bars:
        height = bar.get_height()
        va = 'bottom' if height >= 0 else 'top'
        y_offset = 5 if height >= 0 else -5
        color = 'darkgreen' if height >= 0 else 'darkred'
        ax.annotate(f'{height:,.1f}%',
                   xy=(bar.get_x() + bar.get_width() / 2, height),
                   xytext=(0, y_offset),
                   textcoords="offset points",
                   ha='center', va=va, fontsize=11, fontweight='bold', color=color)
    
    plt.tight_layout()
    return fig

def create_speedup_chart(improvements):
    """Create chart showing speedup factors"""
    fig, ax = plt.subplots(figsize=(12, 7))
    
    metrics = ['p95 Latency', 'p99 Latency', 'Average Latency', 'IOPS', 'Throughput']
    speedup_values = [
        improvements['speedup_p95'],
        improvements['speedup_p99'],
        improvements['speedup_avg'],
        improvements['speedup_iops'],
        improvements['speedup_throughput']
    ]
    
    # Use a sequential color map for speedup factors
    colors = plt.cm.viridis(np.linspace(0.3, 0.9, len(metrics)))
    
    bars = ax.bar(metrics, speedup_values, color=colors, edgecolor='black', linewidth=1.5)
    ax.set_ylabel('Speedup Factor (x)', fontsize=12, fontweight='bold')
    ax.set_title('Hardware Speedup Over Software', fontsize=16, fontweight='bold')
    ax.axhline(y=1, color='black', linewidth=1.5, linestyle='--', label='No Improvement (1x)')
    ax.set_yscale('log')  # Log scale due to huge speedup factors
    ax.grid(True, alpha=0.3, linestyle='--', which='both')
    ax.legend()
    
    # Add value labels
    for bar in bars:
        height = bar.get_height()
        ax.annotate(f'{height:,.1f}x',
                   xy=(bar.get_x() + bar.get_width() / 2, height),
                   xytext=(0, 3),
                   textcoords="offset points",
                   ha='center', va='bottom', fontsize=11, fontweight='bold')
    
    plt.tight_layout()
    return fig

def create_comprehensive_summary_chart(hardware_metrics, software_metrics, improvements):
    """Create a comprehensive summary chart with all key metrics"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    
    # Chart 1: Speedup Factors
    speedup_metrics = ['P95 Latency', 'P99 Latency', 'IOPS', 'Throughput']
    speedup_values = [
        improvements['speedup_p95'],
        improvements['speedup_p99'],
        improvements['speedup_iops'],
        improvements['speedup_throughput']
    ]
    colors = ['#FF6B6B', '#4ECDC4', '#45B7D1', '#96CEB4']
    ax1.bar(speedup_metrics, speedup_values, color=colors)
    ax1.set_ylabel('Speedup (x)')
    ax1.set_title('Hardware Speedup Factors', fontsize=14, fontweight='bold')
    ax1.set_yscale('log')
    ax1.grid(True, alpha=0.3)
    
    # Add value labels
    for i, v in enumerate(speedup_values):
        ax1.text(i, v, f'{v:,.1f}x', ha='center', va='bottom', fontweight='bold')
    
    # Chart 2: Latency Distribution
    latency_types = ['Min/Avg', 'P95', 'P99', 'Max']
    hw_latencies = [
        hardware_metrics['avg_latency_us'],
        hardware_metrics['p95_latency_us'],
        hardware_metrics['p99_latency_us'],
        hardware_metrics['p99_latency_us'] * 1.1  # Approximate max
    ]
    sw_latencies = [
        software_metrics['avg_latency_us'],
        software_metrics['p95_latency_us'],
        software_metrics['p99_latency_us'],
        software_metrics.get('max_latency_us', software_metrics['p99_latency_us'] * 1.5)
    ]
    
    ax2.plot(latency_types, hw_latencies, marker='o', label='Hardware', linewidth=2, color='#2E86AB')
    ax2.plot(latency_types, sw_latencies, marker='s', label='Software', linewidth=2, color='#A23B72')
    ax2.set_xlabel('Latency Type')
    ax2.set_ylabel('Latency (μs)')
    ax2.set_title('Latency Distribution', fontsize=14, fontweight='bold')
    ax2.set_yscale('log')
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    
    plt.suptitle('Hardware vs Software Performance Analysis - Summary', 
                 fontsize=16, fontweight='bold', y=1.02)
    plt.tight_layout()
    return fig

def print_summary_table(hardware_metrics, software_metrics, improvements):
    """Print a summary table of the comparison"""
    print("\n" + "="*80)
    print("HARDWARE VS SOFTWARE PERFORMANCE SUMMARY")
    print("="*80)
    
    print(f"{'Metric':<30} {'Software':<20} {'Hardware':<20} {'Improvement':<20}")
    print("-"*80)
    
    # Latency metrics
    print(f"{'p95 Latency (us)':<30} {software_metrics['p95_latency_us']:<20.2f} {hardware_metrics['p95_latency_us']:<20.2f} {improvements['p95_reduction']:>19.1f}%")
    print(f"{'p99 Latency (us)':<30} {software_metrics['p99_latency_us']:<20.2f} {hardware_metrics['p99_latency_us']:<20.2f} {improvements['p99_reduction']:>19.1f}%")
    print(f"{'Avg Latency (us)':<30} {software_metrics['avg_latency_us']:<20.2f} {hardware_metrics['avg_latency_us']:<20.2f} {improvements['avg_reduction']:>19.1f}%")
    
    # Performance metrics
    print(f"{'IOPS':<30} {software_metrics['iops']:<20,.0f} {hardware_metrics['iops']:<20,.0f} {improvements['iops_increase']:>19.1f}%")
    print(f"{'Throughput (MB/s)':<30} {software_metrics['throughput_mbps']:<20.2f} {hardware_metrics['throughput_mbps']:<20.2f} {improvements['throughput_increase']:>19.1f}%")
    print(f"{'Throughput (GB/s)':<30} {software_metrics['throughput_gbps']:<20.3f} {hardware_metrics['throughput_gbps']:<20.3f} {'-':>19}")
    
    print("-"*80)
    print(f"{'Speedup Factor':<30} {'-':<20} {'-':<20} {'Value':<20}")
    print(f"{'  P95 Latency':<30} {'-':<20} {'-':<20} {improvements['speedup_p95']:>19.1f}x")
    print(f"{'  P99 Latency':<30} {'-':<20} {'-':<20} {improvements['speedup_p99']:>19.1f}x")
    print(f"{'  Average Latency':<30} {'-':<20} {'-':<20} {improvements['speedup_avg']:>19.1f}x")
    print(f"{'  IOPS':<30} {'-':<20} {'-':<20} {improvements['speedup_iops']:>19.1f}x")
    print(f"{'  Throughput':<30} {'-':<20} {'-':<20} {improvements['speedup_throughput']:>19.1f}x")
    
    # Add hardware accelerator speedup if available
    if 'hw_accel_speedup' in software_metrics:
        print("-"*80)
        print(f"{'Hardware Accelerator Speedup':<30} {'-':<20} {'-':<20} {software_metrics['hw_accel_speedup']:>19.1f}x")
        print(f"{'(from software analysis)':<30}")
    
    print("="*80)
    
    # Key takeaways
    print("\nKEY TAKEAWAYS:")
    print(f"1. Hardware is {improvements['speedup_iops']:,.0f}x faster in terms of IOPS")
    print(f"2. Hardware reduces p99 latency by {improvements['p99_reduction']:.1f}%")
    print(f"3. Hardware provides {improvements['throughput_increase']:,.1f}% higher throughput")
    print(f"4. Hardware achieves {hardware_metrics['iops']/1e6:.1f}M IOPS vs Software's {software_metrics['iops']:,.0f} IOPS")
    print(f"5. Hardware p95 latency is {improvements['speedup_p95']:.1f}x better than software")

def main():
    print("Hardware vs Software Performance Analysis")
    print("=" * 60)
    
    # Extract metrics from both files
    print("\nExtracting hardware metrics from hardware_output.txt...")
    hardware_metrics = extract_hardware_metrics('Outputs/hardware_output.txt')
    
    print("Extracting software metrics from software_output.txt...")
    software_metrics = extract_software_metrics('Outputs/software_output.txt')
    
    # Calculate improvements
    improvements = calculate_improvements(hardware_metrics, software_metrics)
    
    # Print summary table
    print_summary_table(hardware_metrics, software_metrics, improvements)
    
    # Create and display charts
    print("\nGenerating comparison charts...")
    
    # Set style for better looking charts
    plt.style.use('seaborn-v0_8-darkgrid')
    
    # Chart 1: Latency Comparison
    print("  Creating latency comparison chart...")
    fig1 = create_latency_comparison_chart(hardware_metrics, software_metrics)
    fig1.savefig('Figures/latency_comparison.png', dpi=300, bbox_inches='tight')
    
    # Chart 2: Performance Comparison
    print("  Creating performance comparison chart...")
    fig2 = create_performance_comparison_chart(hardware_metrics, software_metrics)
    fig2.savefig('Figures/performance_comparison.png', dpi=300, bbox_inches='tight')
    
    # Chart 3: Improvement Percentage
    print("  Creating improvement percentage chart...")
    fig3 = create_improvement_percentage_chart(improvements)
    fig3.savefig('Figures/improvement_percentage.png', dpi=300, bbox_inches='tight')
    
    # Chart 4: Speedup Chart
    print("  Creating speedup chart...")
    fig4 = create_speedup_chart(improvements)
    fig4.savefig('Figures/speedup_comparison.png', dpi=300, bbox_inches='tight')
    
    # Chart 5: Comprehensive Summary
    print("  Creating comprehensive summary chart...")
    fig5 = create_comprehensive_summary_chart(hardware_metrics, software_metrics, improvements)
    fig5.savefig('Figures/comprehensive_summary.png', dpi=300, bbox_inches='tight')
    
    print("\nCharts saved as:")
    print("  1. Figures/latency_comparison.png")
    print("  2. Figures/performance_comparison.png")
    print("  3. Figures/improvement_percentage.png")
    print("  4. Figures/speedup_comparison.png")
    print("  5. Figures/comprehensive_summary.png")
    
    
    print("\nAnalysis complete!")

if __name__ == "__main__":
    main()