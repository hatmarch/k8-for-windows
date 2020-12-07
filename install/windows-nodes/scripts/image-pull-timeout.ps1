$regkey = "HKLM\SYSTEM\CurrentControlSet\Services\kubelet"
$name = "ImagePath"
$(reg query ${regkey} /v ${name} | Out-String) -match "${name}.*(C:.*kubelet\.exe.*)\r"
$kubelet_cmd = $Matches[1]

# what regedit wants and what the powershell command line considers an escape will conflict.  The variable needs to be updated as follows before the google regkey stuff
$kubelet_esc = $kubelet_cmd -replace "\`"","\`"" 
reg add ${regkey} /f /v ${name} /t REG_EXPAND_SZ /d ${kubelet_esc}" "--image-pull-progress-deadline=15m

Restart-Service kubelet -force # our nodes require -force flag to be used
Get-Service kubelet # ensure state is Running