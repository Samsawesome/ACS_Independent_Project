import matplotlib.pyplot as plt
import pandas as pd
import numpy as np
import seaborn as sns
import sys
import os

class WindowsResultVisualizer:
    def __init__(self):
        plt.style.use('seaborn-v0_8')
        self.colors = sns.color_palette("husl", 8)
        
    def load_results(self, csv_file):
        """Load results from CSV file"""
        try:
            return pd.read_csv(csv_file)
        except FileNotFoundError:
            print(f"Error: Could not find {csv_file}")
            return None
    
    def plot_all_experiments(self):
        """Generate all required plots"""
        print("Generating all experiment plots...")
        self.plot_simd_threading_speedup()
        self.plot_density_break_even()
        self.plot_working_set_transitions()
        self.plot_roofline_analysis()
        
    def plot_simd_threading_speedup(self):
        """Plot Experiment 2: SIMD and threading speedup"""
        print("Plotting SIMD and threading speedup...")
        data = self.load_results('speedup_analysis.csv')
        if data is None:
            print("No speedup analysis data found")
            return
            
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 6))
        
        # Single-threaded comparison
        single_thread = data[data['threads'] == 1]
        if not single_thread.empty:
            implementations = single_thread['implementation'].unique()
            for impl in implementations:
                subset = single_thread[single_thread['implementation'] == impl]
                ax1.bar(impl, subset['gflops'].values[0], label=impl, alpha=0.7)
        
        ax1.set_ylabel('GFLOP/s')
        ax1.set_title('Single-Threaded Performance Comparison')
        ax1.legend()
        
        # Thread scaling
        multi_thread = data[data['threads'] > 1]
        if not multi_thread.empty:
            for impl in multi_thread['implementation'].unique():
                subset = multi_thread[multi_thread['implementation'] == impl]
                ax2.plot(subset['threads'], subset['gflops'], 'o-', label=impl, linewidth=2)
        
        ax2.set_xlabel('Thread Count')
        ax2.set_ylabel('GFLOP/s')
        ax2.set_title('Thread Scaling Analysis')
        ax2.legend()
        ax2.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig('simd_threading_speedup.png', dpi=300, bbox_inches='tight')
        plt.show()
        
    def plot_density_break_even(self):
        """Plot Experiment 3: Density break-even analysis"""
        print("Plotting density break-even analysis...")
        data = self.load_results('density_break_even.csv')
        if data is None:
            print("No density break-even data found")
            return
            
        plt.figure(figsize=(10, 6))
        
        # Separate dense and sparse results
        dense_data = data[data['kernel_type'] == 'dense']
        sparse_data = data[data['kernel_type'] == 'csr']
        
        if not dense_data.empty:
            plt.semilogx(dense_data['sparsity'], dense_data['gflops'], 
                        'o-', label='Dense GEMM', linewidth=2, markersize=8)
        
        if not sparse_data.empty:
            plt.semilogx(sparse_data['sparsity'], sparse_data['gflops'], 
                        's-', label='CSR SpMM', linewidth=2, markersize=8)
        
        # Find break-even point (where sparse becomes faster)
        break_even_found = False
        if not dense_data.empty and not sparse_data.empty:
            for sparsity in sorted(dense_data['sparsity'].unique()):
                dense_subset = dense_data[dense_data['sparsity'] == sparsity]
                sparse_subset = sparse_data[sparse_data['sparsity'] == sparsity]
                
                if not dense_subset.empty and not sparse_subset.empty:
                    dense_gflops = dense_subset['gflops'].values[0]
                    sparse_gflops = sparse_subset['gflops'].values[0]
                    
                    if sparse_gflops > dense_gflops and not break_even_found:
                        plt.axvline(x=sparsity, color='red', linestyle='--', 
                                   label=f'Break-even: {sparsity:.3f}')
                        break_even_found = True
                        print(f"Break-even sparsity: {sparsity}")
        
        plt.xlabel('Sparsity')
        plt.ylabel('GFLOP/s')
        plt.title('Density Break-even Analysis')
        plt.legend()
        plt.grid(True, which="both", ls="-", alpha=0.2)
        plt.savefig('density_break_even.png', dpi=300, bbox_inches='tight')
        plt.show()
        
    def plot_working_set_transitions(self):
        """Plot Experiment 4: Working set transitions"""
        print("Plotting working set transitions...")
        data = self.load_results('working_set_transitions.csv')
        if data is None:
            print("No working set transitions data found")
            return
            
        plt.figure(figsize=(10, 6))
        
        plt.plot(data['size'], data['gflops'], 'o-', linewidth=2, markersize=8)
        plt.xlabel('Matrix Size')
        plt.ylabel('GFLOP/s')
        plt.title('Working Set Transitions (Cache Effects)')
        plt.grid(True, alpha=0.3)
        plt.savefig('working_set_transitions.png', dpi=300, bbox_inches='tight')
        plt.show()
        
    def plot_roofline_analysis(self):
        """Plot Experiment 5: Roofline analysis"""
        print("Plotting roofline analysis...")
        data = self.load_results('roofline_analysis.csv')
        if data is None:
            print("No roofline analysis data found")
            return
            
        # Create theoretical roofline (adjust these values for your hardware)
        peak_gflops = 100.0  # Adjust based on your CPU
        memory_bandwidth = 25.0  # GB/s, adjust based on your system
        
        ai = np.logspace(-2, 2, 100)
        compute_bound = np.full_like(ai, peak_gflops)
        memory_bound = memory_bandwidth * ai
        roofline = np.minimum(compute_bound, memory_bound)
        
        plt.figure(figsize=(10, 8))
        
        # Plot roofline
        plt.loglog(ai, roofline, 'k-', linewidth=2, label='Theoretical Roofline')
        plt.fill_between(ai, 0, roofline, alpha=0.2)
        
        # Plot actual measurements
        if not data.empty:
            plt.scatter(data['arithmetic_intensity'], data['gflops'], 
                       s=100, alpha=0.7, label='Dense GEMM', color='blue')
            
            # Annotate points with matrix sizes
            for _, row in data.iterrows():
                plt.annotate(f"{row['size']}", 
                            (row['arithmetic_intensity'], row['gflops']),
                            xytext=(5, 5), textcoords='offset points')
        
        plt.xlabel('Arithmetic Intensity (FLOP/byte)')
        plt.ylabel('Performance (GFLOP/s)')
        plt.title('Roofline Model Analysis')
        plt.legend()
        plt.grid(True, which="both", ls="-", alpha=0.2)
        plt.savefig('roofline_analysis.png', dpi=300, bbox_inches='tight')
        plt.show()

if __name__ == "__main__":
    visualizer = WindowsResultVisualizer()
    visualizer.plot_all_experiments()