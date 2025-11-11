@echo off
echo ===============================================
echo WPRUI Method
echo ===============================================

echo Building I/O tracer...
clang -o io_tracer.exe io_tracer.c -lAdvapi32
if %errorLevel% neq 0 (
    echo Compilation failed
    pause
    exit /b 1
)

echo.
echo Please manually start WPR tracing:
echo 1. Open Start Menu, type "wpr" and run "Windows Performance Recorder"
echo 2. Select "Disk I/O" and "File I/O" 
echo 3. Click "Start"
echo 4. Press Enter here to continue...
pause

echo Running I/O workload...
io_tracer.exe

echo.
echo Please stop the WPR trace manually and save it.
echo Then press Enter...
pause

del io_tracer.exe 2>nul
echo Done!