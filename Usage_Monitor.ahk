#Requires AutoHotkey v1.1.33+
#NoEnv
#Warn
#SingleInstance, Force
SendMode Input
SetWorkingDir, %A_ScriptDir%

; Simple LLM Usage Monitor - standalone app.
; Shows how much of each AI plan's usage limit is left (Codex, Claude, Grok) in a small
; always-on-top popup, with a tray menu and one global hotkey. Run it with AutoHotkey v1.1.33+.
;
; Settings: the tray's "Settings..." or O on the focused popup opens the Settings window, which
; writes %LOCALAPPDATA%\LLMUsageMonitor\settings.ini. Its [Settings] section holds, among others:
;   hotkey=!y           AutoHotkey hotkey syntax (! Alt, ^ Ctrl, + Shift, # Win). Default Alt+Y.
;   anchorMode=screen   screen = float in a screen corner (default); apps = dock to a tracked app
; Command line: /startup reopens the popup only if it was open when the app last ran (the
; "Start with Windows" shortcut passes it). Without it the popup opens straight away.

usageMonitorStandaloneHotkey := ""
usageMonitorStandaloneLinkName := "LLM Usage Monitor.lnk"

; The GUI include ends this auto-execute section (its first label returns), so everything that
; needs its globals runs from this one-shot timer, after the include has initialised.
SetTimer, UsageMonitorStandaloneStartup, -1
#Include %A_ScriptDir%\Usage_Monitor_GUI.ahk

; Keys that act only while the popup has focus. The global hotkey comes from settings.ini.
#If UsageMonitorPopupIsActive()
Esc::
    UsageMonitorHandleEscapeKey()
return

r::
    UsageMonitorRequestRefresh()
return

t::
    UsageMonitorHandleResetsKey()
return

m::
    UsageMonitorToggleViewMode()
return

s::
    UsageMonitorKeyboardSwitchClaudeAccount()
return

a::
    UsageMonitorToggleAccountDisplay()
return

c::
    UsageMonitorToggleTheme()
return

o::
    UsageMonitorShowSettings()
return
#If

UsageMonitorStandaloneStartup:
    UsageMonitorStandaloneBuildTray()
    UsageMonitorStandaloneRegisterHotkey()
    if (UsageMonitorStandaloneHasArg("/startup"))
        UsageMonitorRestoreIfWasVisible()
    else
        ShowUsageMonitorPopup()
return

; One key, two jobs: open or focus the popup, or hand focus back while it
; has focus. It never hides the popup; Esc or the X closes it.
UsageMonitorStandaloneHotkeyPressed:
    if (UsageMonitorPopupIsActive())
        UsageMonitorBlurPopup()
    else
        ToggleUsageMonitorPopup()
return

UsageMonitorStandaloneTrayShow:
    ToggleUsageMonitorPopup()
return

UsageMonitorStandaloneTrayRefresh:
    if (usageMonitorVisible)
        UsageMonitorRequestRefresh()
    else
        ShowUsageMonitorPopup()
return

UsageMonitorStandaloneTrayStartup:
    UsageMonitorStandaloneToggleStartup()
return

UsageMonitorStandaloneTrayOpenData:
    Run, % "explorer.exe """ . usageMonitorDataDir . """"
return

UsageMonitorStandaloneTraySettings:
    UsageMonitorShowSettings()
return

UsageMonitorStandaloneTrayAbout:
    MsgBox, 0x40, Simple LLM Usage Monitor, % "Simple LLM Usage Monitor`n`n"
        . "Shows how much of each AI plan's usage limit is left: Codex, Claude and Grok.`n`n"
        . "Hotkey: " . UsageMonitorStandaloneHotkeyText() . "`n"
        . "Data folder: " . usageMonitorDataDir . "`n`n"
        . "Unofficial. It reads sign-ins that already exist on this PC to ask each provider for your usage."
return

UsageMonitorStandaloneTrayExit:
    ExitApp
return

UsageMonitorStandaloneHasArg(wanted)
{
    local index, arg

    for index, arg in A_Args
    {
        if (arg = wanted)
            return true
    }
    return false
}

UsageMonitorStandaloneRegisterHotkey()
{
    local stored

    IniRead, stored, %usageMonitorStatePath%, Settings, hotkey, !y
    stored := Trim(stored)
    if (stored = "" || stored = "ERROR")
        stored := "!y"
    Hotkey, %stored%, UsageMonitorStandaloneHotkeyPressed, UseErrorLevel
    if (ErrorLevel && stored != "!y")
    {
        TrayTip, Simple LLM Usage Monitor, % "The hotkey " . stored . " in settings.ini is not valid. Using Alt+Y instead.", 5, 2
        stored := "!y"
        Hotkey, %stored%, UsageMonitorStandaloneHotkeyPressed, UseErrorLevel
    }
    usageMonitorStandaloneHotkey := ErrorLevel ? "" : stored
}

; "!^y" -> "Ctrl+Alt+Y" (UsageMonitorHotkeyToText in the GUI library).
UsageMonitorStandaloneHotkeyText()
{
    global usageMonitorStandaloneHotkey
    return UsageMonitorHotkeyToText(usageMonitorStandaloneHotkey)
}

; For the Settings window's hotkey row (reached through Func(), see the GUI library's header).
UsageMonitorStandaloneCurrentHotkey()
{
    global usageMonitorStandaloneHotkey
    return usageMonitorStandaloneHotkey
}

; Settings saved a new hotkey (already checked by UsageMonitorParseHotkeyText). The new key is
; registered first and the old one released only once that worked, so a key Windows or another
; program already owns leaves the old one working. Returns "" on success, else a short message.
UsageMonitorStandaloneApplyHotkey(newHotkey)
{
    local oldHotkey, oldCanonical, errorText

    oldHotkey := usageMonitorStandaloneHotkey
    oldCanonical := ""
    errorText := ""
    if (oldHotkey != "" && UsageMonitorParseHotkeyText(oldHotkey, oldCanonical, errorText) && oldCanonical == newHotkey)
        return ""   ; the same chord written another way ("!^y" vs "^!y"): nothing to do
    Hotkey, %newHotkey%, UsageMonitorStandaloneHotkeyPressed, UseErrorLevel On
    if (ErrorLevel)
        return "Could not use " . UsageMonitorHotkeyToText(newHotkey) . "; "
            . (oldHotkey != "" ? UsageMonitorHotkeyToText(oldHotkey) . " still works." : "no hotkey is set.")
    if (oldHotkey != "")
        Hotkey, %oldHotkey%, Off, UseErrorLevel
    usageMonitorStandaloneHotkey := newHotkey
    IniWrite, %newHotkey%, %usageMonitorStatePath%, Settings, hotkey
    return ""
}

UsageMonitorStandaloneBuildTray()
{
    Menu, Tray, NoStandard
    Menu, Tray, Tip, Simple LLM Usage Monitor
    Menu, Tray, Add, Show usage, UsageMonitorStandaloneTrayShow
    Menu, Tray, Add, Refresh now, UsageMonitorStandaloneTrayRefresh
    Menu, Tray, Add
    Menu, Tray, Add, Start with Windows, UsageMonitorStandaloneTrayStartup
    Menu, Tray, Add, Open data folder, UsageMonitorStandaloneTrayOpenData
    Menu, Tray, Add, Settings..., UsageMonitorStandaloneTraySettings
    Menu, Tray, Add
    Menu, Tray, Add, About, UsageMonitorStandaloneTrayAbout
    Menu, Tray, Add, Exit, UsageMonitorStandaloneTrayExit
    Menu, Tray, Default, Show usage
    Menu, Tray, Click, 1
    UsageMonitorStandaloneUpdateStartupCheck()
}

UsageMonitorStandaloneStartupLinkPath()
{
    global usageMonitorStandaloneLinkName
    return A_Startup . "\" . usageMonitorStandaloneLinkName
}

UsageMonitorStandaloneUpdateStartupCheck()
{
    if (FileExist(UsageMonitorStandaloneStartupLinkPath()))
        Menu, Tray, Check, Start with Windows
    else
        Menu, Tray, Uncheck, Start with Windows
}

UsageMonitorStandaloneToggleStartup()
{
    local linkPath, target, args

    linkPath := UsageMonitorStandaloneStartupLinkPath()
    if (FileExist(linkPath))
    {
        FileDelete, %linkPath%
    }
    else
    {
        ; Bind the shortcut to the interpreter running this script (always v1), never to the
        ; .ahk file association, which can route to AutoHotkey v2 where both are installed.
        if (A_IsCompiled)
        {
            target := A_ScriptFullPath
            args := "/startup"
        }
        else
        {
            target := A_AhkPath
            args := """" . A_ScriptFullPath . """ /startup"
        }
        FileCreateShortcut, %target%, %linkPath%, %A_ScriptDir%, %args%, Simple LLM Usage Monitor
    }
    UsageMonitorStandaloneUpdateStartupCheck()
}
