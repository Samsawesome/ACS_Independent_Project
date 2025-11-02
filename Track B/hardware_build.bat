@echo off
:: Currently not working due to iverilog not fully supporting SystemVerilog
:: Current compile/simulation run is done externally in ModelSim
echo Compiling hardware_blockqueue.sv with Icarus Verilog...


:: Compile with basic Verilog support (not full SystemVerilog)
echo Step 1: Compiling...
iverilog -o hardware_sim hardware_blockqueue.sv -g2005

if errorlevel 1 (
    echo Compilation failed!
    echo.
    pause
    exit /b 1
)

echo Step 2: Running simulation...
vvp hardware_sim

if errorlevel 1 (
    echo Simulation failed!
    pause
    exit /b 1
)

echo.
echo Simulation completed successfully!
pause