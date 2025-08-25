Invoke-Command -ComputerName ttbvmdc01, ttbvmdc02 -ScriptBlock { "$env:COMPUTERNAME`: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
Test-WSMan -ComputerName ttbvmdc01
Get-WinEvent -ComputerName ttbvmdc01 -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddHours(-2)}
Invoke-Command -ComputerName ttbvmdc01 -ScriptBlock { Get-WmiObject -Class Win32_NTLogEvent -Filter "Logfile='Security' AND EventCode=4625" | Select-Object TimeGenerated, Message -First 5 }