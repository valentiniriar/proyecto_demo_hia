' Lanza scripts/vigilar-tunel.sh con Git Bash SIN abrir ventana (lo usa la tarea programada
' "GymHub vigilar tunel", cada 5 minutos). Ver scripts/vigilar-tunel.sh.
Set fso = CreateObject("Scripting.FileSystemObject")
repo = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName)))
bash = "C:\Program Files\Git\bin\bash.exe"
CreateObject("WScript.Shell").Run """" & bash & """ """ & repo & "\scripts\vigilar-tunel.sh""", 0, True
