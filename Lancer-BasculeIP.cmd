@echo off
rem ======================================================================
rem  Lanceur de Switch-IPProfile.ps1 : double-cliquer sur ce fichier.
rem  - Demande l'elevation (UAC) : changer l'adresse IP exige les droits
rem    d'administrateur local.
rem  - RemoteSigned pour ce seul processus : la strategie d'execution du
rem    poste n'est pas modifiee.
rem  - Console masquee (-WindowStyle Hidden) : seule la fenetre s'affiche.
rem  - %~dp0 = dossier de ce lanceur : les profils (Profils-IP.json) sont
rem    lus a cote du script, quelle que soit la lettre de la cle USB.
rem  - Les arguments sont transmis (ex. : Lancer-BasculeIP.cmd -WhatIf).
rem ======================================================================
setlocal
set "SCRIPT=%~dp0Switch-IPProfile.ps1"

if not exist "%SCRIPT%" (
    echo Script introuvable : "%SCRIPT%"
    echo Ce lanceur doit etre dans le meme dossier que Switch-IPProfile.ps1.
    pause
    exit /b 1
)

powershell.exe -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File \"%SCRIPT%\" %*'"
if errorlevel 1 (
    echo.
    echo Elevation refusee ou impossible : relancez et validez la demande UAC
    echo avec un compte administrateur du poste.
    pause
    exit /b 1
)
endlocal
