; Usage Monitor GUI - LLM usage tracking popup (Codex, Claude, Grok, plus an optional add-on column).
; A library: a host script #Includes it. The standard host is
;   Usage_Monitor.ahk (this folder) - the standalone app: tray menu, its own hotkey.
; Any other AutoHotkey v1 script can host it with its own hotkey (host settings below).
; The include ends the host's auto-execute section (its first label returns), so it must be
; the host's last startup line; anything that needs these globals runs from a one-shot timer.
;
; Suppress false-positive #Warn for globals initialized in auto-execute below
; but read inside functions that declare them via `global`.
#Warn, UseUnsetGlobal, Off
;
; Optional host settings, assigned before the #Include (all may stay unset):
;   usageMonitorHostAnchorMode  "apps" docks to tracked app windows; anything else floats on
;                               screen ("screen"). A [Settings] anchorMode in settings.ini wins.
;   usageMonitorHostSpriteFile  full path of an animated GIF for the full view (default: none).
;   usageMonitorHostYieldWindows  "|"-separated WinTitles the popup drops always-on-top for
;                               while any of them exists, e.g. a dictation overlay (default: none).
;   usageMonitorHostHotkeyLabel  text for the Settings window's read-only hotkey row, when the host
;                               owns its hotkey (default: "Set by the host script").
;   usageMonitorHostAddonModule  full path of an add-on provider module (.mjs) that adds one extra
;                               column (see addon-provider.mjs for the contract). This is the ONLY
;                               way to name one: never settings.ini, state or snapshot values. Empty
;                               (the default) = no add-on column; the standalone app leaves it unset.
;   usageMonitorHostDockApps  extra windows to dock to in "apps" mode, beside the built-in Claude,
;                               Codex, VS Code and Grok terminal: "type=kind:value|...", kind one of
;                               title:a,b (a non-terminal window whose title contains a or b),
;                               exe:name.exe (any window of that process) or terminal:a,b (a terminal
;                               window whose title has a or b as a whole word). type names the saved
;                               position (lowercase letters, digits, "-"). Default: none.
; Environment: LLM_USAGE_MONITOR_DATA_DIR replaces the data folder (portable or test use).
;
; Entry points for host hotkeys:
;   ToggleUsageMonitorPopup(), HideUsageMonitorPopup(), UsageMonitorBlurPopup(),
;   UsageMonitorHandleEscapeKey(), UsageMonitorRequestRefresh(), UsageMonitorHandleResetsKey(),
;   UsageMonitorToggleViewMode(), UsageMonitorKeyboardSwitchClaudeAccount(),
;   UsageMonitorToggleAccountDisplay(), UsageMonitorToggleTheme(), UsageMonitorShowSettings(),
;   UsageMonitorRestoreIfWasVisible(), and UsageMonitorPopupIsActive() for #If.
; A host whose Settings hotkey row should be editable defines UsageMonitorStandaloneCurrentHotkey()
; and UsageMonitorStandaloneApplyHotkey(newHotkey) (Usage_Monitor.ahk does); the GUI reaches them
; through Func(), so a host without them loads fine.

if (A_LineFile = A_ScriptFullPath)
{
    ToolTip, Usage_Monitor_GUI.ahk is a library.`nRun Usage_Monitor.ahk to open the LLM usage monitor.
    Sleep, 2500
    ToolTip
    ExitApp
}

usageMonitorVisible := false
usageMonitorGuiReady := false
usageMonitorGuiBuilding := false            ; re-entrancy guard: a build is mid-flight (see UsageMonitorEnsureGui)
usageMonitorHwnd := 0
usageMonitorFetchInFlight := false
usageMonitorFetchPid := 0
usageMonitorFetchOutFile := ""
usageMonitorFetchStatusFile := ""
usageMonitorFetchMode := ""
usageMonitorFetchStartTick := 0
usageMonitorLastFetchStartTick := 0         ; kept after UsageMonitorCleanupFetchFiles, so a resume can tell staleness
usageMonitorShowResetDates := false
usageMonitorTheme := "default"              ; color theme: "default" or "cyberpunk" (persisted)
usageMonitorShowClaudeAccountFull := true   ; full-view account label visible (independent of Resets)
usageMonitorShowClaudeAccountMini := true   ; mini-view account signal visible
usageMonitorMiniCodexMode := "auto"         ; persisted mini mode: auto, on, or off
usageMonitorMiniClaudeMode := "auto"
usageMonitorMiniGrokMode := "auto"
usageMonitorMiniAddonMode := "auto"
usageMonitorMiniCodexEligible := false      ; latest snapshot has at least one usable metric
usageMonitorMiniClaudeEligible := false
usageMonitorMiniGrokEligible := false
usageMonitorMiniAddonEligible := false
; What the mini view ACTUALLY rendered last pass, after mode + eligibility were
; resolved. The resets panel reads these so it can only ever list providers the
; user can currently see - mode alone is not enough, since "auto" depends on
; eligibility and a forced-on provider may be showing "n/a" instead of a metric.
usageMonitorMiniShownCodex := false
usageMonitorMiniShownClaude := false
usageMonitorMiniShownGrok := false
usageMonitorMiniShownAddon := false
; Per-LINE visibility. A provider can be on screen with only one of its two rows
; rendered (a hidden daily promotes the weekly up into the daily row), so the [T]
; panel has to mirror these, not just the per-provider flags above.
usageMonitorMiniShownCodexDaily := false
usageMonitorMiniShownCodexWeekly := false
usageMonitorMiniShownClaudeDaily := false
usageMonitorMiniShownClaudeWeekly := false
usageMonitorMiniShownClaudeFable := false
usageMonitorMiniShownGrokWeekly := false
usageMonitorMiniShownAddonLine1 := false
usageMonitorMiniShownAddonLine2 := false
usageMonitorClaudeAccountShort := ""        ; cached short code (e.g. "j42@") for mini layout
usageMonitorMiniSignalActive := false       ; mini-view account signal control currently in play (claude shown + code known)
usageMonitorMiniDotShown := false           ; mini-view collapsed dot (·) currently visible (hover-gated)
usageMonitorHwndClaudeAccountToggle := 0    ; full-view eye glyph hwnd
usageMonitorHwndClaudeAccountSignal := 0    ; mini-view account signal hwnd
usageMonitorHwndCodexMiniToggle := 0        ; full-view mini visibility controls
usageMonitorHwndClaudeMiniToggle := 0
usageMonitorHwndGrokMiniToggle := 0
usageMonitorHwndAddonMiniToggle := 0
usageMonitorHwndMiniHideCodex := 0          ; mini header hover Hide controls
usageMonitorHwndMiniHideClaude := 0
usageMonitorHwndMiniHideGrok := 0
usageMonitorHwndMiniHideAddon := 0
usageMonitorResetsPanelHwnd := 0            ; mini-view transient resets panel hwnd
usageMonitorResetsPanelVisible := false     ; mini-view resets panel currently shown
usageMonitorLastSnapshot := ""
usageMonitorLastSnapshotStatus := ""
usageMonitorViewMode := "full"
usageMonitorClaudeProfile := ""
usageMonitorClaudeProfileChoices := ""
usageMonitorClaudeNextProfile := ""
usageMonitorClaudeProfileSwitchAvailable := false
usageMonitorAnchorTarget := "auto"
usageMonitorAnchorCorner := "bottom-left"
usageMonitorAnchorMarginX := 16
usageMonitorAnchorMarginY := 38
usageMonitorAnchorTrackIntervalMs := 150
; Anchor mode, resolved by UsageMonitorLoadAnchorMode: "apps" docks to a tracked app window and
; parks while none is open; "screen" floats in a corner of the primary monitor's work area (or
; wherever it was dragged), never parks, and keeps refreshing while the user is at the PC.
usageMonitorAnchorMode := ""
usageMonitorScreenCorner := "bottom-right"
usageMonitorScreenMarginX := 16
usageMonitorScreenMarginY := 16
; A WSL/Ubuntu terminal running a Grok dashboard is a valid anchor when its window title
; contains this marker (case-insensitive). Only terminal-host windows are matched this way,
; so the HUD docks to the Grok shell but not to every random terminal. Set to "" to disable.
usageMonitorGrokTerminalTitleMatch := "grok"
; Anchor follows the last-focused tracked app window (Claude / Codex / VS Code /
; Grok terminal / a host dock app) so a view toggle re-stacks against the
; window you were actually using, not a fixed app priority.
; Owned/non-resizable windows (modal dialogs such as VS Code's external-link trust
; prompt) are excluded as anchor candidates so the HUD stays docked to the main editor.
usageMonitorLastTrackedHwnd := 0
; Current tracked-app type whose bottom-left hook is loaded (vscode, claude, codex,
; grok-terminal, or a host dock app's type). Swapping this loads that type's saved offset.
usageMonitorAnchorType := ""
; Set true during a view-mode rebuild: the GUI is destroyed/recreated, which briefly
; surfaces another window (e.g. VS Code). While set, that transient is neither chosen as
; the anchor nor remembered, so the overlay stays anchored to the real last-focused window.
usageMonitorSuppressAnchorCapture := false
; --- Auto-refresh cadence ---------------------------------------------------
; A snapshot costs ~1.5s wall / 641ms CPU and six HTTPS requests carrying live
; session cookies (Codex session+usage, Claude orgs+usage, Grok credits+subs),
; so cadence is a network-politeness question, not a CPU one. The underlying
; numbers move slowly - measured ~1.9%/min for Codex and ~0.7%/min for Claude
; under heavy use - so a fixed fast poll would re-fetch identical values on the
; large majority of ticks while quadrupling request volume against three
; providers that sit behind bot protection.
; Instead the cadence adapts to observed change:
;   the snapshot changed something on screen -> poll again at the fast interval
;   nothing changed                          -> back off, doubling each tick
; The backoff ceiling is the old fixed interval, so the cadence is never slower
; than before and is up to 4x faster while values are actually moving. A focused
; popup also pins the fast tier - the user is looking straight at it.
usageMonitorAutoRefreshMs := 60000        ; idle cadence, and the backoff ceiling
usageMonitorAutoRefreshFastMs := 15000    ; cadence while values are moving
usageMonitorAutoRefreshMinMs := 5000      ; floor for the [Debug] override
usageMonitorAutoRefreshOverrideMs := 0    ; [Debug] autoRefreshMs - fixed cadence, disables adaptation
usageMonitorRefreshIdleStreakMax := 4     ; cap so the doubling can't overflow
usageMonitorRefreshIdleStreak := 0        ; consecutive no-change snapshots
usageMonitorSnapshotChanged := false      ; set by ApplySnapshot's change gate
; True while the in-flight fetch is an automatic one: it must not blank the
; metrics to "Refreshing..." first, because the whole point of the auto tick is
; that values change in place without a visible load cycle.
usageMonitorFetchSilent := false
; --- Change gates -----------------------------------------------------------
; Every GuiControl write invalidates its control and repaints it, so the old
; unconditional rewrite of all six metrics (plus bars, mini layout, sprite and
; a synchronous whole-window RedrawWindow) was itself the flicker. These caches
; record what was last actually written so a steady-state refresh - which is
; most of them - becomes a literal no-op on screen. All are cleared by
; UsageMonitorResetControlState whenever the GUI is rebuilt, since the control
; handles and their contents are recreated from scratch.
usageMonitorLastCtrlText := {}            ; control var  -> last text written
usageMonitorLastBarState := {}            ; bar hwnd     -> "usedPct|colorRef"
usageMonitorMiniLayoutKey := ""           ; last mini provider layout signature
usageMonitorSpriteApplied := 0            ; sprite hwnd already shown/click-through
usageMonitorLoginHintCollapsed := false   ; retired hint stub already collapsed
usageMonitorLastAccountDisplay := ""      ; last Claude account label render key
; --- DPI / size scaling (popup is sized for the monitor it appears on) -------
; All popup GUIs are created with -DPIScale, so every coordinate in this script
; (Gui Add/Move, WinGetPos, MouseGetPos, hit-zones) lives in ONE space: raw
; physical pixels. Scaling is owned explicitly by UsScale/UsFont from the REAL
; DPI of the monitor the popup shows on (thread-PMv2 GetDpiForMonitor query —
; the plain call is virtualized and would return the system DPI for every
; monitor). Total on-screen magnification vs the 96-DPI design ("target"):
;   "auto"  : target = min(monitorDPI/96, cap below) — physical size parity
;             with the design on a 100% monitor, capped so high-DPI displays
;             don't blow the popup up. A 100% monitor renders byte-for-byte.
;   <number>: force that exact total magnification on every monitor (e.g. 1.0 =
;             identical pixel size everywhere; 1.25 = a touch larger than 100%).
; Coordinates and fonts need different factors (a system-DPI-aware window is
; DWM-stretched by monDPI/A_ScreenDPI, and GDI renders point sizes at
; A_ScreenDPI regardless of -DPIScale):
;   coordScale = target * A_ScreenDPI / monDPI   (usageMonitorUiScale)
;   fontScale  = target * 96 / monDPI            (usageMonitorUiFontScale)
; Lower usageMonitorUiScaleCap to make the popup smaller on high-DPI monitors.
usageMonitorUiScaleMode := "auto"
usageMonitorUiScaleCap := 1.5
usageMonitorUiScale := 1.0
usageMonitorUiFontScale := 1.0
usageMonitorBuiltUiScale := ""
usageMonitorBuiltViewMode := ""
usageMonitorThemeBg := "1E1E1E"
usageMonitorThemeTextPrimary := "D4D4D4"
usageMonitorThemeTextSecondary := "4E4E4E"
usageMonitorThemeTextAccent := "F44747"
usageMonitorFullNormalAlpha := 255
usageMonitorFullHoverAlpha := 26
usageMonitorCtrlColors := {}
usageMonitorCtrlBgColors := {}
usageMonitorCtrlBgBrushes := {}
usageMonitorBgBrush := 0
usageMonitorButtons := {}
usageMonitorButtonGroups := {}
usageMonitorButtonHoverGroup := ""
usageMonitorButtonPressedGroup := ""
usageMonitorTooltipGroup := ""
usageMonitorTooltipStartTick := 0
usageMonitorTooltipMouseX := ""
usageMonitorTooltipMouseY := ""
usageMonitorTooltipShown := false
usageMonitorTooltipDelayMs := 2000
usageMonitorTooltipId := 20
usageMonitorHwndRefreshBtn := 0
usageMonitorHwndViewToggleBtn := 0
usageMonitorHwndResetToggleBtn := 0
usageMonitorHwndThemeBtn := 0
usageMonitorFooterBaseYHelp := 0
usageMonitorFooterBaseYRefresh := 0
usageMonitorFooterBaseYResets := 0
usageMonitorLoginHintBaseY := 0
usageMonitorErrorShownHeight := 0
usageMonitorHwndCodexHeader := 0
usageMonitorHwndCodexDaily := 0
usageMonitorHwndCodexWeekly := 0
usageMonitorHwndClaudeHeader := 0
usageMonitorHwndClaudeAccount := 0
usageMonitorHwndClaudeDaily := 0
usageMonitorHwndClaudeWeekly := 0
usageMonitorHwndGrokHeader := 0
usageMonitorHwndGrokMonthly := 0
usageMonitorHwndCodexDailyBar := 0
usageMonitorHwndCodexWeeklyBar := 0
usageMonitorHwndClaudeDailyBar := 0
usageMonitorHwndClaudeWeeklyBar := 0
usageMonitorHwndGrokMonthlyBar := 0
usageMonitorHwndClaudeFable := 0
usageMonitorHwndAddonHeader := 0
usageMonitorHwndAddonLine1 := 0
usageMonitorHwndAddonLine2 := 0
usageMonitorHwndAddonLine1Bar := 0
usageMonitorHwndAddonLine2Bar := 0
usageMonitorHwndClaudeFableBar := 0
usageMonitorClaudeFableActive := false  ; last snapshot carried a per-model (Fable) weekly line (claude_line_3)
usageMonitorBuiltClaudeFable := false   ; the current GUI build includes the Fable row (full view builds it conditionally)
usageMonitorHwndMiniDivider := 0
usageMonitorHwndMiniDivider2 := 0
usageMonitorHwndMiniDivider3 := 0
usageMonitorHwndSprite := 0
usageMonitorHwndSpritePlaceholder := 0
usageMonitorGrokLinkActive := false     ; full-view Grok "Open Grok" link currently active (Grok fetch failed)
usageMonitorSpritePath := ""
usageMonitorSpriteFile := usageMonitorHostSpriteFile   ; host setting; empty = no sprite
; The add-on column (addon-provider.mjs), fixed for the life of the process: copied once from the
; host setting and never assigned anywhere else. The label, link, hint and warning arrive in each
; snapshot (addon_* keys) as display text; the label is kept in [State] addonLabel for when the
; add-on is switched off and its module is not loaded.
usageMonitorAddonModule := usageMonitorHostAddonModule   ; host setting; empty = no add-on column
usageMonitorAddonActive := (usageMonitorAddonModule != "")
usageMonitorAddonLabel := "Add-on"
usageMonitorAddonLink := ""
usageMonitorAddonHint := ""
usageMonitorAddonWarning := ""
usageMonitorYieldWindowTitles := UsageMonitorSplitTitleList(usageMonitorHostYieldWindows)   ; host setting; empty = never yield
usageMonitorDockApps := UsageMonitorParseDockApps(usageMonitorHostDockApps)   ; host setting; empty = built-in apps only
usageMonitorNodeInstallInFlight := false
usageMonitorNodeInstallPid := 0
usageMonitorNodeInstallOutFile := ""
usageMonitorNodeInstallStatusFile := ""
usageMonitorNodePromptHandled := false
usageMonitorPassthroughActive := false
usageMonitorWindowAlpha := ""
usageMonitorWindowAlphaHwnd := 0
usageMonitorHwndLoginHint := 0
usageMonitorHwndHelp := 0
usageMonitorHwndDragHandle := 0
; Paths, set by UsageMonitorInitPaths below: this folder, the per-user data folder
; (%LOCALAPPDATA%\<usageMonitorAppDirName>) and settings.ini inside it.
usageMonitorAppDirName := "LLMUsageMonitor"   ; working name; the public name is still open
usageMonitorDir := ""
usageMonitorDataDir := ""
usageMonitorStatePath := ""
usageMonitorHwndCloseBtn := 0
usageMonitorCloseBtnShown := false
usageMonitorDragged := false
usageMonitorDragOffsetX := 0
usageMonitorDragOffsetY := 0
usageMonitorDragInProgress := false
; Set only after mini -> full restore, then cleared once the cursor leaves full view.
usageMonitorTransparencyHoldUntilLeave := false
usageMonitorTransparencyHoldSawInside := false
usageMonitorFlashHwndT := 0
usageMonitorFlashHwndB := 0
usageMonitorFlashHwndL := 0
usageMonitorFlashHwndR := 0
; Last window that held focus before the popup did. UsageMonitorBlurPopup activates it to
; give focus back, so Alt+Y-while-focused / Esc-dismiss leave the user where they started.
usageMonitorPrevActiveHwnd := 0
; --- Idle tiers and auto-attach -----------------------------------------------
; A shown popup costs something only while it polls: the 150ms anchor tick, the 200ms
; focus-border check, and a snapshot (PowerShell + Node) every 15-60s. The tracking polls run only
; while someone is using the popup; the snapshot keeps running while the overlay is on screen, so
; its numbers stay current whatever app has focus. Only being away stops it.
;   active     - a tracked app or the popup has focus: everything runs
;   hover      - another app has focus but the cursor is over the popup: tracking tick + refresh
;   background - another app has focus: refresh only; tracking waits for a SHELLHOOK event or a hover
;   away       - no input for usageMonitorAwayAfterMs: nothing runs until the first raw input
; When the last tracked window closes or minimizes, the popup parks instead of closing: hidden,
; still restored on the next start, and re-shown when one appears. Two wake paths, because a
; single one proved unreliable: SHELLHOOK events (with a retry ladder, since Electron windows and
; title-matched windows only qualify seconds after their first event) and a cheap parked poll.
usageMonitorAwayAfterMs := 300000
usageMonitorIdleTier := ""                  ; current tier; "" while hidden
usageMonitorParked := false                 ; hidden only because no tracked window is open
usageMonitorParkRetryStep := 0              ; next index into the parked wake retry ladder
usageMonitorParkRetryDelays := [1500, 4000, 10000]   ; re-checks after the first 300ms attempt
usageMonitorParkedPollMs := 2000            ; fallback anchor check while parked (one window scan)
usageMonitorShellHookMsg := 0               ; SHELLHOOK message number while listening, else 0
usageMonitorShellHookUnavailable := false   ; registration failed: never sleep or park
usageMonitorRawInputWakeActive := false     ; listening for the first input after going away
usageMonitorRawInputUnavailable := false    ; registration failed: never enter away
usageMonitorInputSeenTick := 0              ; when the raw-input wake last fired
; --- Settings window (release plan D5) -----------------------------------------------
; Per-provider choices from [Providers] in settings.ini (UsageMonitorLoadProviderPrefs):
; codex / claude / grok = auto | cli | firefox | off, addon = on | off (only with an add-on module).
; Every refresh passes them to the bridge as -Providers; a provider that is off makes no request at
; all, and an add-on that is off is not even loaded.
usageMonitorProviderPrefs := {codex: "auto", claude: "auto", grok: "auto", addon: "on"}
usageMonitorOffCodex := false               ; the last render showed the provider as off
usageMonitorOffClaude := false
usageMonitorOffGrok := false
usageMonitorOffAddon := false
usageMonitorBuiltTheme := ""                ; theme the current GUI build was drawn in
usageMonitorRefreshQueued := false          ; a Settings change waits for the in-flight fetch
usageMonitorSettingsHwnd := 0               ; the Settings window, while open
usageMonitorSettingsInitial := ""           ; the values it opened with (only changes are saved)
UsageMonitorInitPaths()
; Keep this the last assignment in the block. A host's hotkeys are live while its auto-execute
; section is still running, so its popup hotkey can arrive before the globals above exist;
; ShowUsageMonitorPopup refuses to open until then instead of running with blank settings.
usageMonitorGlobalsReady := true

ToggleUsageMonitorPopup()
{
    global usageMonitorVisible

    if (usageMonitorVisible)
    {
        UsageMonitorFocusPopup()
        return
    }

    ShowUsageMonitorPopup()
}

; automatic = true when the popup opens itself (startup restore, or a tracked window appearing
; while parked): no "no tracked app" tooltip, and a recent snapshot is reused instead of forcing
; a visible reload.
ShowUsageMonitorPopup(automatic := false)
{
    global usageMonitorVisible, usageMonitorStatePath, usageMonitorGlobalsReady
    global usageMonitorTransparencyHoldUntilLeave, usageMonitorTransparencyHoldSawInside
    global usageMonitorIdleTier, usageMonitorParked, usageMonitorLastSnapshot

    if (!usageMonitorGlobalsReady)
        return false

    ; Re-read the mode on every open, so a settings.ini edit applies without a restart.
    UsageMonitorLoadAnchorMode()
    screenMode := UsageMonitorScreenAnchorActive()
    targetHwnd := screenMode ? 0 : UsageMonitorGetAnchorWindow()
    if (!screenMode && !targetHwnd)
    {
        if (!automatic)
        {
            ToolTip, No tracked app window is available.
            SetTimer, UsageMonitorHideQuickTip, -3000
        }
        return false
    }

    UsageMonitorRememberPrevActiveWindow()
    UsageMonitorLoadViewMode()
    UsageMonitorLoadTheme()
    UsageMonitorLoadRefreshOverride()
    UsageMonitorLoadProviderPrefs()
    UsageMonitorLoadClaudeProfile()
    UsageMonitorLoadShowClaudeAccountFull()
    UsageMonitorLoadShowClaudeAccountMini()
    UsageMonitorLoadMiniProviderVisibility()
    usageMonitorTransparencyHoldUntilLeave := false
    usageMonitorTransparencyHoldSawInside := false
    UsageMonitorClearLegacyPinState()
    UsageMonitorLoadPositionForType(screenMode ? "screen" : UsageMonitorAnchorTypeFor(targetHwnd))
    UsageMonitorApplyUiScale(targetHwnd)   ; 0 in screen mode: scales for the screen anchor point
    UsageMonitorEnsureGui()
    usageMonitorVisible := true
    usageMonitorParked := false
    SetTimer, UsageMonitorParkedPollTimer, Off
    SetTimer, UsageMonitorIdleWakeTimer, Off
    usageMonitorIdleTier := "active"   ; the first tracking tick settles the real tier
    IniWrite, 1, %usageMonitorStatePath%, State, visible
    UsageMonitorSetError("")
    Gui, UsageMon:Show, AutoSize NoActivate, LLM Usage Monitor
    UsageMonitorScheduleSpriteBuild()
    UsageMonitorApplyAnchor()
    UsageMonitorUpdatePassthrough()
    UsageMonitorStartAnchorTracking()
    SetTimer, UsageMonitorFocusBorderCheck, 200
    UsageMonitorEnsureShellHook()
    if (automatic && IsObject(usageMonitorLastSnapshot))
        UsageMonitorResumeAutoRefresh()
    else
        UsageMonitorRequestRefresh()
    return true
}

UsageMonitorFocusPopup()
{
    global usageMonitorVisible, usageMonitorHwnd

    if (!usageMonitorVisible || !usageMonitorHwnd)
        return false

    if (!WinExist("ahk_id " . usageMonitorHwnd))
        return false

    UsageMonitorRememberPrevActiveWindow()
    WinRestore, ahk_id %usageMonitorHwnd%
    WinActivate, ahk_id %usageMonitorHwnd%
    WinWaitActive, ahk_id %usageMonitorHwnd%,, 1
    if (!ErrorLevel)
    {
        return true
    }
    return false
}

; Record whichever window currently owns focus, unless that window is the popup itself.
; Called from the show/focus paths and from the 200ms focus-border poll, so the stored hwnd is
; always the app the user was in before the overlay took focus.
UsageMonitorRememberPrevActiveWindow()
{
    ; Leading `local` => assume-global for everything else (usageMonitorHwnd, ...Panel Hwnd,
    ; ...PrevActiveHwnd). Mixing a `global` line in here is a v1 parse error.
    local activeHwnd

    WinGet, activeHwnd, ID, A
    if (!activeHwnd)
        return
    if (usageMonitorHwnd && activeHwnd = usageMonitorHwnd)
        return
    if (usageMonitorResetsPanelHwnd && activeHwnd = usageMonitorResetsPanelHwnd)
        return
    if (usageMonitorSettingsHwnd && activeHwnd = usageMonitorSettingsHwnd)
        return
    usageMonitorPrevActiveHwnd := activeHwnd
}

; Drop the popup's focus WITHOUT closing it: the overlay stays on screen and only the selected
; state (red focus border) goes away. This is what Alt+Y does while the popup is focused --
; Alt+Y never hides the overlay any more, Esc is the close path. The transient mini resets
; panel is part of the selected state, so it is torn down here too.
UsageMonitorBlurPopup()
{
    local target, minMax

    if (!usageMonitorVisible || !usageMonitorHwnd)
        return false
    if (!WinActive("ahk_id " . usageMonitorHwnd))
        return false

    UsageMonitorHideMiniResetsPanel()
    UsageMonitorHideHoverTooltip()

    target := 0
    if (usageMonitorPrevActiveHwnd && usageMonitorPrevActiveHwnd != usageMonitorHwnd
        && WinExist("ahk_id " . usageMonitorPrevActiveHwnd))
    {
        ; Never un-minimize something just to hand focus back.
        WinGet, minMax, MinMax, ahk_id %usageMonitorPrevActiveHwnd%
        if (minMax != -1)
            target := usageMonitorPrevActiveHwnd
    }
    if (!target)
    {
        target := UsageMonitorGetAnchorWindow()
        if (target = usageMonitorHwnd)
            target := 0
    }

    if (target)
    {
        WinActivate, ahk_id %target%
        WinWaitActive, ahk_id %target%, , 0.5
    }

    UsageMonitorHideFocusBorder()
    return true
}

; Esc dispatcher for the focused popup. When the transient mini resets panel is up, Esc is a
; dismiss: it closes the panel and unselects the overlay but leaves it on screen. Otherwise Esc
; closes the popup outright (the primary close path -- Alt+Y only toggles focus).
UsageMonitorHandleEscapeKey()
{
    global usageMonitorResetsPanelVisible

    if (usageMonitorResetsPanelVisible)
    {
        UsageMonitorHideMiniResetsPanel()
        UsageMonitorBlurPopup()
        return
    }

    HideUsageMonitorPopup()
}

UsageMonitorShowFocusBorder()
{
    global usageMonitorHwnd
    global usageMonitorFlashHwndT, usageMonitorFlashHwndB, usageMonitorFlashHwndL, usageMonitorFlashHwndR

    if (!usageMonitorHwnd)
        return

    WinGetPos, px, py, pw, ph, ahk_id %usageMonitorHwnd%
    if (pw = "" || pw <= 0 || ph = "" || ph <= 0)
        return

    pad := 3

    if (!usageMonitorFlashHwndT)
    {
        ; -DPIScale: strip sizes come from WinGetPos physical pixels; without it, Gui Show's
        ; W/H would be re-multiplied by A_ScreenDPI/96 on high-DPI systems (oversized frame).
        Gui, UsageMonFlashT:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorFlashHwndT
        Gui, UsageMonFlashB:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorFlashHwndB
        Gui, UsageMonFlashL:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorFlashHwndL
        Gui, UsageMonFlashR:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorFlashHwndR
    }
    ; Recolor on every show, not just at creation: the strips outlive a theme toggle (which
    ; destroys and rebuilds only the popup), so coloring them once would latch whichever theme
    ; happened to be active the first time the focus border appeared.
    Gui, UsageMonFlashT:Color, % UsageMonitorThemeRgb("bad")
    Gui, UsageMonFlashB:Color, % UsageMonitorThemeRgb("bad")
    Gui, UsageMonFlashL:Color, % UsageMonitorThemeRgb("bad")
    Gui, UsageMonFlashR:Color, % UsageMonitorThemeRgb("bad")

    tx := px - pad, ty := py - pad, tw := pw + pad * 2, th := pad
    bx := px - pad, by := py + ph, bw := pw + pad * 2, bh := pad
    lx := px - pad, ly := py, lw := pad, lh := ph
    rx := px + pw,  ry := py, rw := pad, rh := ph

    Gui, UsageMonFlashT:Show, x%tx% y%ty% w%tw% h%th% NoActivate, UsageMonFlashFrame
    Gui, UsageMonFlashB:Show, x%bx% y%by% w%bw% h%bh% NoActivate, UsageMonFlashFrame
    Gui, UsageMonFlashL:Show, x%lx% y%ly% w%lw% h%lh% NoActivate, UsageMonFlashFrame
    Gui, UsageMonFlashR:Show, x%rx% y%ry% w%rw% h%rh% NoActivate, UsageMonFlashFrame

    DllCall("SetWindowPos", "Ptr", usageMonitorFlashHwndT, "Ptr", usageMonitorHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
    DllCall("SetWindowPos", "Ptr", usageMonitorFlashHwndB, "Ptr", usageMonitorHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
    DllCall("SetWindowPos", "Ptr", usageMonitorFlashHwndL, "Ptr", usageMonitorHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
    DllCall("SetWindowPos", "Ptr", usageMonitorFlashHwndR, "Ptr", usageMonitorHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
}

UsageMonitorHideFocusBorder()
{
    global usageMonitorFlashHwndT, usageMonitorFlashHwndB, usageMonitorFlashHwndL, usageMonitorFlashHwndR
    if (usageMonitorFlashHwndT)
    {
        Gui, UsageMonFlashT:Hide
        Gui, UsageMonFlashB:Hide
        Gui, UsageMonFlashL:Hide
        Gui, UsageMonFlashR:Hide
    }
}

;   silent = true  -> automatic tick: do not blank the metrics to "Refreshing...".
;                     Values simply change in place when the new ones land, and a
;                     failure still surfaces through the error row.
;   silent = false -> the user asked (R / Refresh / account switch / first open),
;                     so the load state is the acknowledgement that the keypress
;                     registered.
UsageMonitorRequestRefresh(silent := false)
{
    global usageMonitorVisible, usageMonitorNodePromptHandled
    global usageMonitorFetchInFlight, usageMonitorFetchSilent

    if (!usageMonitorVisible)
        return false

    ; A manual request while a silent auto-tick is already in flight promotes that
    ; fetch to visible rather than reporting "refresh in progress" - the user pressed
    ; R and has to see something happen. The same PID keeps being polled.
    if (usageMonitorFetchInFlight && !silent && usageMonitorFetchSilent)
    {
        usageMonitorFetchSilent := false
        UsageMonitorSetError("")
        UsageMonitorSetState("Refreshing...")
        return true
    }

    usageMonitorNodePromptHandled := false
    if (!silent)
    {
        UsageMonitorSetState("Refreshing...")
        UsageMonitorSetError("")
    }
    return UsageMonitorTriggerRefresh("Snapshot", silent)
}

; Delay for the next automatic tick. Fast while the popup is focused or while the
; last snapshot actually moved something; otherwise doubling from the fast interval
; up to (never past) the idle interval, so an idle overlay polls exactly as often as
; it did before this became adaptive.
UsageMonitorNextAutoRefreshMs()
{
    local delay, idx

    if (usageMonitorAutoRefreshOverrideMs > 0)
        return usageMonitorAutoRefreshOverrideMs
    if (usageMonitorHwnd && WinActive("ahk_id " . usageMonitorHwnd))
        return usageMonitorAutoRefreshFastMs

    delay := usageMonitorAutoRefreshFastMs
    idx := usageMonitorRefreshIdleStreak
    while (idx > 0 && delay < usageMonitorAutoRefreshMs)
    {
        delay := delay * 2
        idx -= 1
    }
    if (delay > usageMonitorAutoRefreshMs)
        delay := usageMonitorAutoRefreshMs
    return delay
}

; Fold one completed snapshot into the cadence. A snapshot that changed something
; resets to the fast tier; an unchanged one backs off a step. Called only from the
; poll-completion path - a rebuild (theme / view / Fable toggle) re-applies the same
; snapshot and must not be mistaken for an idle tick.
UsageMonitorAfterSnapshotApplied()
{
    global usageMonitorSnapshotChanged, usageMonitorRefreshIdleStreak, usageMonitorRefreshIdleStreakMax

    if (usageMonitorSnapshotChanged)
        usageMonitorRefreshIdleStreak := 0
    else if (usageMonitorRefreshIdleStreak < usageMonitorRefreshIdleStreakMax)
        usageMonitorRefreshIdleStreak += 1
    UsageMonitorScheduleAutoRefresh()
}

; [Settings] refreshSeconds (the Settings window's Refresh choice) sets a fixed cadence: 0 keeps
; the adaptive one. While that key is absent, the older [Debug] autoRefreshMs still works, for
; measuring a candidate interval by hand. Both are clamped to a floor so a stray value cannot
; turn the overlay into a request flood against the provider APIs; unparsable leaves adaptation on.
UsageMonitorLoadRefreshOverride()
{
    local stored, seconds

    IniRead, seconds, %usageMonitorStatePath%, Settings, refreshSeconds, %A_Space%
    seconds := Trim(seconds, " `t`r`n")
    if (RegExMatch(seconds, "^\d+$"))
    {
        stored := seconds * 1000
        if (stored <= 0)
            usageMonitorAutoRefreshOverrideMs := 0
        else
            usageMonitorAutoRefreshOverrideMs := (stored < usageMonitorAutoRefreshMinMs) ? usageMonitorAutoRefreshMinMs : stored
        return
    }

    IniRead, stored, %usageMonitorStatePath%, Debug, autoRefreshMs, 0
    stored := stored + 0
    if (stored <= 0)
    {
        usageMonitorAutoRefreshOverrideMs := 0
        return
    }
    if (stored < usageMonitorAutoRefreshMinMs)
        stored := usageMonitorAutoRefreshMinMs
    usageMonitorAutoRefreshOverrideMs := stored
}

UsageMonitorScheduleAutoRefresh(delayMs := "")
{
    global usageMonitorVisible, usageMonitorIdleTier

    ; Outside a refreshing tier the next snapshot waits for the user to come back
    ; (UsageMonitorResumeAutoRefresh) instead of running for nobody.
    if (!usageMonitorVisible || !UsageMonitorTierRefreshes(usageMonitorIdleTier))
        return false

    delayMs := delayMs + 0
    if (delayMs <= 0)
        delayMs := UsageMonitorNextAutoRefreshMs()

    SetTimer, UsageMonitorAutoRefreshTimer, Off
    SetTimer, UsageMonitorAutoRefreshTimer, -%delayMs%
    return true
}

; keepArmed = true only from UsageMonitorParkPopup: hidden, but still restored on the next start
; and re-shown when a tracked window appears. A user close (Esc, X) is always a real close.
HideUsageMonitorPopup(keepArmed := false)
{
    global usageMonitorVisible, usageMonitorStatePath
    global usageMonitorTransparencyHoldUntilLeave, usageMonitorTransparencyHoldSawInside
    global usageMonitorIdleTier, usageMonitorParked

    usageMonitorVisible := false
    usageMonitorIdleTier := ""
    usageMonitorTransparencyHoldUntilLeave := false
    usageMonitorTransparencyHoldSawInside := false
    if (!keepArmed)
    {
        usageMonitorParked := false
        IniWrite, 0, %usageMonitorStatePath%, State, visible
        UsageMonitorReleaseShellHook()
        SetTimer, UsageMonitorIdleWakeTimer, Off
        SetTimer, UsageMonitorParkedPollTimer, Off
    }
    UsageMonitorSetRawInputWake(false)
    UsageMonitorSetPassthrough(false)
    UsageMonitorHideMiniResetsPanel()
    UsageMonitorHideHoverTooltip()
    SetTimer, UsageMonitorAutoRefreshTimer, Off
    UsageMonitorStopAnchorTracking()
    UsageMonitorHideFocusBorder()
    Gui, UsageMon:Hide
}

; Scale a control coordinate / size by the current popup UI scale.
; Returns the value unchanged when scale = 1.0 so the "perfect" monitor renders
; exactly as before (no rounding drift), otherwise rounds to the nearest pixel.
UsScale(n)
{
    global usageMonitorUiScale
    if (usageMonitorUiScale = 1.0)
        return n
    v := Round(n * usageMonitorUiScale)
    return (v < 1 ? 1 : v)
}

; Scale a font point size. Fonts use their own factor (usageMonitorUiFontScale):
; GDI renders point sizes at A_ScreenDPI even with -DPIScale, so the factor
; that lands fonts at the same on-screen magnification as the UsScale'd boxes
; is target*96/monDPI, not the coordinate factor. Keeps one decimal place so
; the font tracks control widths (integer rounding made fonts ~4% too big for
; their boxes, wrapping the help line). Identity at scale 1.0 for zero drift.
UsFont(pt)
{
    global usageMonitorUiFontScale
    if (usageMonitorUiFontScale = 1.0)
        return pt
    v := Round(pt * usageMonitorUiFontScale, 1)
    return (v < 1 ? 1 : v)
}

; ===== Color themes =====
; Each slot is an RGB hex string ("RRGGBB"). The build lays down the ACTIVE palette directly --
; every Gui Font/Color call routes its color through UsageMonitorThemeRgb -- and
; UsageMonitorApplyTheme() then syncs the paint-path color map, so switching themes only needs
; a rebuild + this pass (no per-control edits). Building in the active palette is what makes a
; missed WM_CTLCOLORSTATIC harmless: AHK's own fallback handling paints the color baked in at
; creation, so that fallback must already be right. "default" is the
; original VS Code-ish dark scheme; "cyberpunk" is the recovered Cyberpunk 2077 palette.
; Palette values are 0xRRGGBB integer literals (parsed at parse-time — avoids unreliable
; runtime hex-string conversion). UsageMonitorThemeRgb formats them to "RRGGBB" for Gui Font /
; Color; UsageMonitorThemeRef byte-swaps to a 0xBBGGRR COLORREF for the paint path.
UsageMonitorThemePalette(themeName)
{
    static def := { bg: 0x1E1E1E, header: 0x569CD6, text: 0xD4D4D4, dim: 0x909090
        , dimmer: 0x858585, good: 0x4EC9B0, warn: 0xCCA700, bad: 0xF44747
        , track: 0x2D2D2D, divider: 0x808080, btnHover: 0x303030, btnPressed: 0x3F3F3F
        , close: 0xFF5555, drag: 0x888888, strong: 0xFFFFFF, hint: 0x8A8A8A }
    ; "cyberpunk" = deep-red neon chrome: near-black red-tinted bg, neon-crimson headers/
    ; dividers. Metric colors (good/warn/bad) deliberately keep green/yellow/red so usage
    ; health is still readable at a glance (red chrome, semantic metrics).
    ; "hint" is the footer key-help text. It is its own role because "divider" is a bar
    ; color too dark for text. Default values must stay unique (UsageMonitorApplyTheme's
    ; remap is keyed by them); theme-contrast.test.mjs checks that and the 4.5:1 contrast.
    static cyber := { bg: 0x1A0E10, header: 0xFF2D55, text: 0xE0CED0, dim: 0x9C8588
        , dimmer: 0x8F767A, good: 0x00E060, warn: 0xFCED23, bad: 0xFF3B30
        , track: 0x2A1518, divider: 0x8C2F3A, btnHover: 0x3A1E22, btnPressed: 0x4A282D
        , close: 0xFF4D4D, drag: 0x9C8588, strong: 0xFFFFFF, hint: 0xC9606F }
    return (themeName = "cyberpunk") ? cyber : def
}

UsageMonitorThemeRgb(slot)
{
    global usageMonitorTheme
    return Format("{:06X}", UsageMonitorThemePalette(usageMonitorTheme)[slot])
}

; 0xRRGGBB integer -> 0xBBGGRR COLORREF (for SetTextColor / progress-bar SendMessage / brushes).
UsageMonitorRgbIntToBgr(rgb)
{
    return ((rgb & 0xFF) * 65536) + (((rgb >> 8) & 0xFF) * 256) + ((rgb >> 16) & 0xFF)
}

UsageMonitorThemeRef(slot)
{
    global usageMonitorTheme
    return UsageMonitorRgbIntToBgr(UsageMonitorThemePalette(usageMonitorTheme)[slot])
}

; Sync the WM_CTLCOLORSTATIC color map to the active theme by mapping each DEFAULT role COLORREF
; to the current theme's value. The controls themselves are already built in the active palette;
; this pass still matters because the map is registered with default-palette literals (they are
; the stable role identity) and because bar/divider colors travel by PBM_ message, not Gui Font.
; Idempotent: when the theme is default the map is identity; a second call finds already-themed
; values that aren't keys. Metric (good/warn/bad) colors come from UsageMonitorGetMetricColorRef
; (themed directly) and are re-applied by the next snapshot.
UsageMonitorApplyTheme()
{
    global usageMonitorTheme, usageMonitorCtrlColors, usageMonitorCtrlBgColors, usageMonitorButtons
    global usageMonitorHwnd, usageMonitorHwndMiniDivider, usageMonitorHwndMiniDivider2
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar, usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndClaudeFableBar, usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar
    global usageMonitorCtrlBgBrushes

    defPal := UsageMonitorThemePalette("default")
    remap := {}
    ; Every slot that appears as a DEFAULT literal in usageMonitorCtrlColors/BgColors must be
    ; listed here, or that control's map entry silently keeps its Default color while the
    ; control itself is built themed. "good"/"warn" are deliberately absent: metric colors are
    ; only ever written at runtime from UsageMonitorThemeRef, never as a default literal.
    for _, slot in ["bg", "header", "text", "dim", "dimmer", "bad", "close", "drag", "btnHover", "btnPressed", "track", "divider", "hint"]
        remap[UsageMonitorRgbIntToBgr(defPal[slot])] := UsageMonitorThemeRef(slot)

    for hwnd, col in usageMonitorCtrlColors
        if (remap.HasKey(col))
            usageMonitorCtrlColors[hwnd] := remap[col]
    for hwnd, col in usageMonitorCtrlBgColors
        if (remap.HasKey(col))
            usageMonitorCtrlBgColors[hwnd] := remap[col]
    for hwnd, btn in usageMonitorButtons
    {
        for _, prop in ["defaultText", "hoverText", "pressedText", "defaultBg", "hoverBg", "pressedBg"]
            if (remap.HasKey(btn[prop]))
                btn[prop] := remap[btn[prop]]
    }

    ; Window background + drop cached brushes so WM_CTLCOLORSTATIC rebuilds them in the new bg.
    bgHex := UsageMonitorThemeRgb("bg")
    Gui, UsageMon:Color, %bgHex%, %bgHex%
    UsageMonitorReleaseBgBrushes()

    ; Metric-bar tracks are set via PBM_ message, not ctrlColors. (Mini dividers are ordinary
    ; statics now and ride the usageMonitorCtrlBgColors remap above.)
    trackRef := UsageMonitorThemeRef("track")
    for _, barHwnd in [usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar, usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar, usageMonitorHwndClaudeFableBar, usageMonitorHwndGrokMonthlyBar, usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar]
        if (barHwnd)
            SendMessage, 0x2001, 0, %trackRef%, , ahk_id %barHwnd%

    for hwnd, _ in usageMonitorCtrlColors
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", true)
    if (usageMonitorHwnd)
        DllCall("InvalidateRect", "Ptr", usageMonitorHwnd, "Ptr", 0, "Int", true)
}

; Real effective DPI of the monitor under hwnd (e.g. 96 = 100%, 144 = 150%, 240 = 250%).
; GetDpiForMonitor(MDT_EFFECTIVE) is VIRTUALIZED by the calling thread's DPI awareness:
; an unaware thread always gets 96 and a system-aware thread (this AHK process) gets the
; sign-in system DPI for every monitor. To read the true per-monitor value, temporarily
; switch this thread to PER_MONITOR_AWARE_V2 around the query, then restore. On systems
; without SetThreadDpiAwarenessContext (pre-Win10 1607) the unwrapped call runs as before.
; Returns 0 on any failure (caller falls back to 1.0).
UsageMonitorGetWindowDpi(hwnd)
{
    ; Screen mode has no anchor window (hwnd 0): use the monitor under the screen anchor point.
    ; The point is in this script's own coordinate space, so look the monitor up before the
    ; thread switches DPI context; the handle stays valid for GetDpiForMonitor afterwards.
    hMon := 0, px := 0, py := 0
    if (!hwnd && UsageMonitorScreenAnchorActive())
    {
        UsageMonitorScreenAnchorPoint(px, py)
        hMon := DllCall("MonitorFromPoint", "Int64", (px & 0xFFFFFFFF) | (py << 32), "UInt", 2, "Ptr")  ; MONITOR_DEFAULTTONEAREST
    }
    prevCtx := DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")  ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    if (!hMon)
        hMon := DllCall("MonitorFromWindow", "Ptr", hwnd + 0, "UInt", 2, "Ptr")  ; MONITOR_DEFAULTTONEAREST
    dpiX := 0, dpiY := 0
    if (hMon)
        hr := DllCall("shcore\GetDpiForMonitor", "Ptr", hMon, "Int", 0, "UInt*", dpiX, "UInt*", dpiY, "UInt")  ; MDT_EFFECTIVE_DPI
    else
        hr := -1
    if (prevCtx)
        DllCall("SetThreadDpiAwarenessContext", "Ptr", prevCtx, "Ptr")
    if (hr != 0 || dpiX <= 0)
        return 0
    return dpiX
}

; Build scales for the popup on the monitor under refHwnd (raw physical pixels,
; -DPIScale on every popup GUI). "target" is the desired total on-screen
; magnification vs the 96-DPI design:
;   auto  -> target = min(monDpi/96, cap)   (physical parity, capped)
;   fixed -> target = the number
; A system-DPI-aware window is DWM-stretched by monDpi/A_ScreenDPI on monitors
; whose DPI differs from the system DPI (no stretch when they match), and GDI
; renders font point sizes at A_ScreenDPI regardless of -DPIScale, so the two
; factors diverge:
;   coordScale = target * A_ScreenDPI / monDpi   (control x/y/w/h -> UsScale)
;   fontScale  = target * 96 / monDpi            (point sizes     -> UsFont)
; On a 96-DPI system both equal the old single scale (byte-identical render).
UsageMonitorComputeLogicalScale(refHwnd, ByRef coordScale, ByRef fontScale)
{
    global usageMonitorUiScaleMode, usageMonitorUiScaleCap
    coordScale := 1.0
    fontScale := 1.0
    monDpi := UsageMonitorGetWindowDpi(refHwnd)
    if (monDpi <= 0)
        return
    dpiMag := monDpi / 96.0
    if (usageMonitorUiScaleMode = "auto")
    {
        cap := usageMonitorUiScaleCap + 0.0
        if (cap <= 0)
            cap := 1.5
        target := (dpiMag < cap) ? dpiMag : cap
    }
    else
    {
        target := usageMonitorUiScaleMode + 0.0
        if (target <= 0)
            target := 1.0
    }
    coordScale := Round(target * A_ScreenDPI / monDpi, 3)
    fontScale := Round(target * 96.0 / monDpi, 3)
    if (coordScale <= 0)
        coordScale := 1.0
    if (fontScale <= 0)
        fontScale := 1.0
}

; Recompute the popup scales for the monitor it's about to show on. If the GUI was
; already built at a different scale (e.g. VS Code moved to another monitor), tear
; it down so EnsureGui rebuilds it at the new scale on the next show. fontScale is
; derived from the same inputs as coordScale, so comparing coordScale alone would
; miss nothing on real monitors — but compare both anyway for safety.
UsageMonitorApplyUiScale(refHwnd)
{
    global usageMonitorUiScale, usageMonitorUiFontScale, usageMonitorBuiltUiScale, usageMonitorGuiReady
    global usageMonitorBuiltViewMode, usageMonitorViewMode, usageMonitorBuiltTheme, usageMonitorTheme
    coordScale := 1.0
    fontScale := 1.0
    UsageMonitorComputeLogicalScale(refHwnd, coordScale, fontScale)
    usageMonitorUiScale := coordScale
    usageMonitorUiFontScale := fontScale
    ; A theme changed while the popup was hidden (Settings, or T in the other host) also needs a
    ; rebuild: the hidden GUI still holds the old palette.
    if (usageMonitorGuiReady && (usageMonitorBuiltUiScale != (usageMonitorUiScale . "|" . usageMonitorUiFontScale)
        || usageMonitorBuiltViewMode != usageMonitorViewMode || usageMonitorBuiltTheme != usageMonitorTheme))
    {
        Gui, UsageMon:Destroy
        usageMonitorGuiReady := false
    }
}

; Paths that must not depend on the host: this folder comes from A_LineFile, so the GUI works
; wherever its folder sits. The data folder is per user; LLM_USAGE_MONITOR_DATA_DIR replaces it
; (portable or test use). Runs once from the auto-execute section, so it stays cheap.
UsageMonitorInitPaths()
{
    local envDir, localAppData

    SplitPath, A_LineFile,, usageMonitorDir
    EnvGet, envDir, LLM_USAGE_MONITOR_DATA_DIR
    if (envDir != "")
    {
        usageMonitorDataDir := RTrim(envDir, "\/")
    }
    else
    {
        EnvGet, localAppData, LOCALAPPDATA
        if (localAppData = "")
            localAppData := A_AppData
        usageMonitorDataDir := localAppData . "\" . usageMonitorAppDirName
    }
    FileCreateDir, %usageMonitorDataDir%\tmp
    usageMonitorStatePath := usageMonitorDataDir . "\settings.ini"
    UsageMonitorLoadAnchorMode()
}

; [Settings] anchorMode in settings.ini wins; otherwise the host's default; otherwise "screen".
UsageMonitorLoadAnchorMode()
{
    local stored, fallback

    fallback := (usageMonitorHostAnchorMode = "apps") ? "apps" : "screen"
    IniRead, stored, %usageMonitorStatePath%, Settings, anchorMode, %fallback%
    usageMonitorAnchorMode := (stored = "apps" || stored = "screen") ? stored : fallback
}

UsageMonitorScreenAnchorActive()
{
    global usageMonitorAnchorMode
    return (usageMonitorAnchorMode = "screen")
}

; For a host's #If: true only while this script's own popup has focus. Matching by handle,
; not by title, keeps two hosts (or an older copy) from catching each other's keys.
UsageMonitorPopupIsActive()
{
    global usageMonitorHwnd
    return (usageMonitorHwnd && WinActive("ahk_id " . usageMonitorHwnd))
}

; Tiers in which the visible overlay keeps auto-refreshing, docked or floating: a docked popup
; stays on screen while another app has focus, so its numbers must not freeze. Only away pauses it.
UsageMonitorTierRefreshes(tier)
{
    return (tier = "active" || tier = "hover" || tier = "background")
}

UsageMonitorLoadViewMode()
{
    global usageMonitorStatePath, usageMonitorViewMode
    IniRead, storedViewMode, %usageMonitorStatePath%, State, viewMode, full
    usageMonitorViewMode := (storedViewMode = "mini") ? "mini" : "full"
}

UsageMonitorPersistViewMode()
{
    global usageMonitorStatePath, usageMonitorViewMode
    IniWrite, %usageMonitorViewMode%, %usageMonitorStatePath%, State, viewMode
}

UsageMonitorLoadTheme()
{
    global usageMonitorStatePath, usageMonitorTheme
    IniRead, storedTheme, %usageMonitorStatePath%, State, theme, default
    usageMonitorTheme := (storedTheme = "cyberpunk") ? "cyberpunk" : "default"
}

UsageMonitorPersistTheme()
{
    global usageMonitorStatePath, usageMonitorTheme
    IniWrite, %usageMonitorTheme%, %usageMonitorStatePath%, State, theme
}

UsageMonitorSafeProfileName(profileName)
{
    profileName := Trim(profileName, " `t`r`n")
    if (profileName = "")
        return ""
    if (InStr(profileName, "..") || InStr(profileName, "\") || InStr(profileName, "/")
        || InStr(profileName, ":") || InStr(profileName, "*") || InStr(profileName, "?")
        || InStr(profileName, """") || InStr(profileName, "<") || InStr(profileName, ">")
        || InStr(profileName, "|"))
        return ""
    if (!RegExMatch(profileName, "^[A-Za-z0-9._ -]+$"))
        return ""
    return profileName
}

UsageMonitorLoadClaudeProfile()
{
    global usageMonitorStatePath, usageMonitorClaudeProfile
    ; %A_Space% = blank when the key is missing. An empty default makes IniRead return the word
    ; ERROR, which passes the name check and showed up as a "Claude profile" on fresh installs.
    IniRead, storedProfile, %usageMonitorStatePath%, State, claudeProfile, %A_Space%
    usageMonitorClaudeProfile := UsageMonitorSafeProfileName(storedProfile)
}

UsageMonitorPersistClaudeProfile()
{
    global usageMonitorStatePath, usageMonitorClaudeProfile
    safeProfile := UsageMonitorSafeProfileName(usageMonitorClaudeProfile)
    usageMonitorClaudeProfile := safeProfile
    IniWrite, %safeProfile%, %usageMonitorStatePath%, State, claudeProfile
}

; --- Per-provider choices ([Providers] in settings.ini) ----------------------------------
; A missing key takes the default (an add-on is on: the host that named it chose to show it). A
; value that cannot be read turns that provider off, so a typo never makes requests the user meant
; to stop.
UsageMonitorParseProviderPref(provider, stored)
{
    local value

    value := Trim(stored, " `t`r`n")
    StringLower, value, value
    if (value = "")
        return (provider = "addon") ? "on" : "auto"
    if (provider = "addon")
        return (value = "on") ? "on" : "off"
    if (value = "auto" || value = "cli" || value = "firefox" || value = "off")
        return value
    return "off"
}

; Read on every show and every refresh, so a Save from the other host applies on the next tick.
; The add-on key is read only when this host has an add-on.
UsageMonitorLoadProviderPrefs()
{
    local index, provider, stored

    for index, provider in (usageMonitorAddonActive ? ["codex", "claude", "grok", "addon"] : ["codex", "claude", "grok"])
    {
        IniRead, stored, %usageMonitorStatePath%, Providers, %provider%, %A_Space%
        usageMonitorProviderPrefs[provider] := UsageMonitorParseProviderPref(provider, stored)
    }
}

UsageMonitorProviderPref(provider)
{
    global usageMonitorProviderPrefs
    return usageMonitorProviderPrefs.HasKey(provider) ? usageMonitorProviderPrefs[provider] : "auto"
}

; The bridge's -Providers value. Only a-z, "=" and ",", which the parse above guarantees. The add-on
; choice is sent only when this host has an add-on.
UsageMonitorProvidersArg()
{
    global usageMonitorAddonActive
    return "codex=" . UsageMonitorProviderPref("codex") . ",claude=" . UsageMonitorProviderPref("claude")
        . ",grok=" . UsageMonitorProviderPref("grok")
        . (usageMonitorAddonActive ? ",addon=" . UsageMonitorProviderPref("addon") : "")
}

; Off in this render: the snapshot says so, or the provider was switched off since it was taken.
UsageMonitorProviderShownOff(provider, status)
{
    return (status = "off" || UsageMonitorProviderPref(provider) = "off")
}

UsageMonitorProviderDisplayName(provider)
{
    if (provider = "codex")
        return "Codex"
    if (provider = "claude")
        return "Claude"
    if (provider = "grok")
        return "Grok"
    return UsageMonitorAddonDisplayLabel()
}

; The add-on column's header text: the module's own label (from the snapshot, kept in [State]).
UsageMonitorAddonDisplayLabel()
{
    global usageMonitorAddonLabel
    return (usageMonitorAddonLabel != "") ? usageMonitorAddonLabel : "Add-on"
}

; The add-on's header link, used only if it is a plain https URL (the scraper checks the same
; pattern): no query, port, "%" escapes, quotes or spaces, so it can never become a command line.
UsageMonitorAddonLinkIsSafe(url)
{
    return RegExMatch(url, "^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$") > 0
}

; --- Hotkey text ------------------------------------------------------------------------
; "!^y" -> "Ctrl+Alt+Y". Hotkey prefixes that change behaviour, not keys (* ~ $ < >), are dropped.
UsageMonitorHotkeyToText(hk)
{
    local ch, mods, key

    if (hk = "")
        return "(none)"
    mods := {}
    while (StrLen(hk) > 1 && InStr("^!+#*~$<>", ch := SubStr(hk, 1, 1)))
    {
        mods[ch] := true
        hk := SubStr(hk, 2)
    }
    key := (StrLen(hk) = 1) ? Format("{:U}", hk) : hk
    return (mods["^"] ? "Ctrl+" : "") . (mods["#"] ? "Win+" : "") . (mods["!"] ? "Alt+" : "")
        . (mods["+"] ? "Shift+" : "") . key
}

; "Ctrl+Alt+Y" or AutoHotkey's "^!y" -> canonical "^!y" in ahkHotkey. Returns false with a short
; reason in errorText for anything that is not one key plus modifiers, or that would get in the
; way: a key with no modifier (it would fire while typing), Shift alone with a typing key,
; Win+L (locks the PC), and Ctrl+Shift+Alt+Win (Windows treats that chord as the Office key).
UsageMonitorParseHotkeyText(text, ByRef ahkHotkey, ByRef errorText)
{
    local raw, mods, key, parts, index, part, lowerPart, m, m1, m2, hasCtrl, hasAlt, hasShift, hasWin, modCount, keyLower

    ahkHotkey := ""
    errorText := ""
    raw := Trim(text, " `t`r`n")
    if (raw = "")
    {
        errorText := "Type a hotkey, e.g. Ctrl+Alt+Y."
        return false
    }
    hasCtrl := false, hasAlt := false, hasShift := false, hasWin := false
    if (RegExMatch(raw, "^([\^!+#]+)([^\^!+#\s&*~$<>]+)$", m))
    {
        mods := m1
        key := m2
        hasCtrl := InStr(mods, "^") > 0, hasAlt := InStr(mods, "!") > 0
        hasShift := InStr(mods, "+") > 0, hasWin := InStr(mods, "#") > 0
        if (StrLen(mods) != hasCtrl + hasAlt + hasShift + hasWin)
        {
            errorText := "Each modifier can appear only once."
            return false
        }
    }
    else
    {
        parts := StrSplit(raw, "+", " `t")
        key := parts.Pop()
        for index, part in parts
        {
            StringLower, lowerPart, part
            if ((lowerPart = "ctrl" || lowerPart = "control") && !hasCtrl)
                hasCtrl := true
            else if (lowerPart = "alt" && !hasAlt)
                hasAlt := true
            else if (lowerPart = "shift" && !hasShift)
                hasShift := true
            else if ((lowerPart = "win" || lowerPart = "windows") && !hasWin)
                hasWin := true
            else if (RegExMatch(lowerPart, "^(ctrl|control|alt|shift|win|windows)$"))
            {
                errorText := "Each modifier can appear only once."
                return false
            }
            else
            {
                errorText := "Not a modifier: " . SubStr(part, 1, 20) . ". Use Ctrl, Alt, Shift or Win."
                return false
            }
        }
    }
    key := Trim(key)
    StringLower, keyLower, key
    if (key = "" || !RegExMatch(key, "^([A-Za-z][A-Za-z0-9_]*|[0-9``\-=\[\];',./\\])$")
        || (GetKeyVK(key) = 0 && GetKeySC(key) = 0))
    {
        errorText := "Not a key AutoHotkey knows: " . SubStr(key, 1, 20) . "."
        return false
    }
    if (RegExMatch(keyLower, "^(l|r)?(ctrl|control|alt|shift|win)$"))
    {
        errorText := "Add a key after the modifiers, e.g. Ctrl+Alt+Y."
        return false
    }
    modCount := hasCtrl + hasAlt + hasShift + hasWin
    if (modCount = 0 && !RegExMatch(keyLower, "^f(1[3-9]|2[0-4])$"))
    {
        errorText := "Add Ctrl, Alt or Win: a key on its own would fire while typing."
        return false
    }
    if (modCount = 1 && hasShift && (StrLen(key) = 1 || keyLower = "space"))
    {
        errorText := "Shift alone types a character; add Ctrl, Alt or Win."
        return false
    }
    if (modCount = 4)
    {
        errorText := "Ctrl+Shift+Alt+Win is the Office key on Windows; drop one modifier."
        return false
    }
    if (hasWin && modCount = 1 && keyLower = "l")
    {
        errorText := "Win+L locks the PC; pick another key."
        return false
    }
    if (StrLen(key) = 1)
        key := keyLower
    ahkHotkey := (hasCtrl ? "^" : "") . (hasAlt ? "!" : "") . (hasShift ? "+" : "") . (hasWin ? "#" : "") . key
    return true
}

UsageMonitorLoadShowClaudeAccountFull()
{
    global usageMonitorStatePath, usageMonitorShowClaudeAccountFull
    IniRead, storedShow, %usageMonitorStatePath%, State, showClaudeAccountFull, 1
    usageMonitorShowClaudeAccountFull := (storedShow != "0")
}

UsageMonitorPersistShowClaudeAccountFull()
{
    global usageMonitorStatePath, usageMonitorShowClaudeAccountFull
    showValue := usageMonitorShowClaudeAccountFull ? 1 : 0
    IniWrite, %showValue%, %usageMonitorStatePath%, State, showClaudeAccountFull
}

UsageMonitorLoadShowClaudeAccountMini()
{
    global usageMonitorStatePath, usageMonitorShowClaudeAccountMini
    IniRead, storedShow, %usageMonitorStatePath%, State, showClaudeAccountMini, 1
    usageMonitorShowClaudeAccountMini := (storedShow != "0")
}

UsageMonitorPersistShowClaudeAccountMini()
{
    global usageMonitorStatePath, usageMonitorShowClaudeAccountMini
    showValue := usageMonitorShowClaudeAccountMini ? 1 : 0
    IniWrite, %showValue%, %usageMonitorStatePath%, State, showClaudeAccountMini
}

UsageMonitorLoadMiniProviderVisibility()
{
    global usageMonitorStatePath
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    IniRead, storedCodexMode, %usageMonitorStatePath%, State, miniCodexMode, __missing__
    IniRead, storedAddonMode, %usageMonitorStatePath%, State, miniAddonMode, __missing__
    IniRead, storedClaudeMode, %usageMonitorStatePath%, State, miniClaudeMode, __missing__
    IniRead, storedGrokMode, %usageMonitorStatePath%, State, miniGrokMode, __missing__
    IniRead, legacyCodex, %usageMonitorStatePath%, State, miniCodexVisible, 1
    IniRead, legacyClaude, %usageMonitorStatePath%, State, miniClaudeVisible, 1
    IniRead, legacyGrok, %usageMonitorStatePath%, State, miniGrokVisible, 1
    usageMonitorMiniCodexMode := UsageMonitorNormalizeMiniProviderMode(storedCodexMode, legacyCodex)
    usageMonitorMiniClaudeMode := UsageMonitorNormalizeMiniProviderMode(storedClaudeMode, legacyClaude)
    usageMonitorMiniGrokMode := UsageMonitorNormalizeMiniProviderMode(storedGrokMode, legacyGrok)
    usageMonitorMiniAddonMode := UsageMonitorNormalizeMiniProviderMode(storedAddonMode)
    UsageMonitorLoadAddonLabel()
}

; The add-on's last known header label, so the column keeps its name while the add-on is off
; (its module is then not loaded, so the snapshot carries no label).
UsageMonitorLoadAddonLabel()
{
    global usageMonitorStatePath, usageMonitorAddonLabel
    IniRead, storedLabel, %usageMonitorStatePath%, State, addonLabel, %A_Space%
    if (UsageMonitorAddonLabelIsValid(storedLabel))
        usageMonitorAddonLabel := storedLabel
}

; Same limits as addon-provider.mjs: up to 7 characters of letters, digits, space and . _ + -
UsageMonitorAddonLabelIsValid(label)
{
    return RegExMatch(label, "^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,6}$") > 0
}

UsageMonitorNormalizeMiniProviderMode(storedMode, legacyVisible := 1)
{
    StringLower, normalized, storedMode
    if (normalized = "auto" || normalized = "free" || normalized = "on" || normalized = "off")
        return normalized
    return (legacyVisible = "0") ? "off" : "auto"
}

UsageMonitorPersistMiniProviderVisibility()
{
    global usageMonitorStatePath
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    IniWrite, %usageMonitorMiniCodexMode%, %usageMonitorStatePath%, State, miniCodexMode
    IniWrite, %usageMonitorMiniClaudeMode%, %usageMonitorStatePath%, State, miniClaudeMode
    IniWrite, %usageMonitorMiniGrokMode%, %usageMonitorStatePath%, State, miniGrokMode
    IniWrite, %usageMonitorMiniAddonMode%, %usageMonitorStatePath%, State, miniAddonMode
}

UsageMonitorSetMiniProviderMode(providerName, mode)
{
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    global usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus, usageMonitorViewMode

    mode := UsageMonitorNormalizeMiniProviderMode(mode)

    if (providerName = "codex")
        usageMonitorMiniCodexMode := mode
    else if (providerName = "claude")
        usageMonitorMiniClaudeMode := mode
    else if (providerName = "grok")
        usageMonitorMiniGrokMode := mode
    else if (providerName = "addon")
        usageMonitorMiniAddonMode := mode
    else
        return false

    UsageMonitorPersistMiniProviderVisibility()
    UsageMonitorUpdateMiniProviderToggleText()
    if (usageMonitorViewMode = "mini" && IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
    return true
}

; Compatibility entry point used by the mini hover Hide controls.
UsageMonitorSetMiniProviderVisible(providerName, isVisible)
{
    return UsageMonitorSetMiniProviderMode(providerName, isVisible ? "auto" : "off")
}

UsageMonitorToggleMiniProvider(providerName)
{
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    if (providerName = "codex")
        currentMode := usageMonitorMiniCodexMode
    else if (providerName = "claude")
        currentMode := usageMonitorMiniClaudeMode
    else if (providerName = "grok")
        currentMode := usageMonitorMiniGrokMode
    else if (providerName = "addon")
        currentMode := usageMonitorMiniAddonMode
    else
        return false
    nextMode := (currentMode = "auto") ? "free" : ((currentMode = "free") ? "on" : ((currentMode = "on") ? "off" : "auto"))
    return UsageMonitorSetMiniProviderMode(providerName, nextMode)
}

UsageMonitorUpdateMiniProviderToggleText()
{
    global usageMonitorViewMode
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    global usageMonitorMiniCodexEligible, usageMonitorMiniClaudeEligible, usageMonitorMiniGrokEligible, usageMonitorMiniAddonEligible
    global UsageMonCodexMiniToggle, UsageMonClaudeMiniToggle, UsageMonGrokMiniToggle, UsageMonAddonMiniToggle
    global usageMonitorAddonActive

    if (usageMonitorViewMode != "full")
        return false
    changed := false
    if (UsageMonitorSetCtrlText("UsageMonCodexMiniToggle", UsageMonitorMiniProviderModeText(usageMonitorMiniCodexMode, usageMonitorMiniCodexEligible)))
        changed := true
    if (UsageMonitorSetCtrlText("UsageMonClaudeMiniToggle", UsageMonitorMiniProviderModeText(usageMonitorMiniClaudeMode, usageMonitorMiniClaudeEligible)))
        changed := true
    if (UsageMonitorSetCtrlText("UsageMonGrokMiniToggle", UsageMonitorMiniProviderModeText(usageMonitorMiniGrokMode, usageMonitorMiniGrokEligible)))
        changed := true
    if (usageMonitorAddonActive && UsageMonitorSetCtrlText("UsageMonAddonMiniToggle", UsageMonitorMiniProviderModeText(usageMonitorMiniAddonMode, usageMonitorMiniAddonEligible)))
        changed := true
    return changed
}

UsageMonitorMiniProviderModeText(mode, eligible)
{
    if (mode = "off")
        return "Mini: Off"
    if (mode = "free")
        return "Mini: Free"
    if (mode = "on")
        return "Mini: On"
    return eligible ? "Mini: Auto" : "Mini: Auto-hidden"
}

UsageMonitorClearLegacyPinState()
{
    global usageMonitorStatePath

    ; Pin used a single global offset. Per-type memory is a clean slate: drop the
    ; old keys so a leftover Pin value cannot leak into every window type.
    IniDelete, %usageMonitorStatePath%, State, rememberPosition
    IniDelete, %usageMonitorStatePath%, State, dragged
    IniDelete, %usageMonitorStatePath%, State, dragOffsetX
    IniDelete, %usageMonitorStatePath%, State, dragOffsetY
}

UsageMonitorLoadPositionForType(type)
{
    global usageMonitorStatePath, usageMonitorAnchorType
    global usageMonitorDragged, usageMonitorDragOffsetX, usageMonitorDragOffsetY

    usageMonitorAnchorType := type
    usageMonitorDragged := false
    usageMonitorDragOffsetX := 0
    usageMonitorDragOffsetY := 0
    if (type = "")
        return

    IniRead, stored, %usageMonitorStatePath%, Positions, %type%, __missing__
    if (stored = "" || stored = "__missing__" || stored = "ERROR")
        return

    StringSplit, posParts, stored, |
    if (posParts0 < 2)
        return
    if posParts1 is not number
        return
    if posParts2 is not number
        return

    usageMonitorDragOffsetX := posParts1 + 0
    usageMonitorDragOffsetY := posParts2 + 0
    usageMonitorDragged := true
}

UsageMonitorPersistPositionForType(type)
{
    global usageMonitorStatePath, usageMonitorDragged
    global usageMonitorDragOffsetX, usageMonitorDragOffsetY

    if (type = "" || !usageMonitorDragged)
        return

    stored := usageMonitorDragOffsetX . "|" . usageMonitorDragOffsetY
    IniWrite, %stored%, %usageMonitorStatePath%, Positions, %type%
}

UsageMonitorSyncPositionToAnchor()
{
    global usageMonitorAnchorType

    if (UsageMonitorScreenAnchorActive())
        newType := "screen"
    else
        newType := UsageMonitorAnchorTypeFor(UsageMonitorGetAnchorWindow())
    if (newType = usageMonitorAnchorType)
        return
    UsageMonitorLoadPositionForType(newType)
}

UsageMonitorCaptureCurrentDragOffset()
{
    global usageMonitorHwnd, usageMonitorDragged, usageMonitorDragOffsetX, usageMonitorDragOffsetY
    global usageMonitorAnchorType

    if (!usageMonitorHwnd)
        return false
    if (UsageMonitorScreenAnchorActive())
        return UsageMonitorCaptureScreenPosition()

    WinGetPos, popX, popY, popW, popH, ahk_id %usageMonitorHwnd%
    if (popW = "" || popW <= 0 || popH = "" || popH <= 0)
        return false

    if (!UsageMonitorResolveAnchorBounds(targetLeft, targetTop, targetRight, targetBottom))
        return false

    usageMonitorDragOffsetX := popX - targetLeft
    usageMonitorDragOffsetY := targetBottom - (popY + popH)
    usageMonitorDragged := true
    type := usageMonitorAnchorType
    if (type = "")
        type := UsageMonitorAnchorTypeFor(UsageMonitorGetAnchorWindow())
    if (type != "")
        usageMonitorAnchorType := type
    UsageMonitorPersistPositionForType(type)
    return true
}

UsageMonitorToggleViewMode()
{
    global usageMonitorViewMode, usageMonitorGuiReady, usageMonitorVisible, usageMonitorHwnd
    global usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus
    global usageMonitorTransparencyHoldUntilLeave, usageMonitorTransparencyHoldSawInside
    global usageMonitorSuppressAnchorCapture

    ; Remember whether the popup currently has focus (e.g. M pressed while focused). The
    ; rebuild below uses NoActivate, which would otherwise drop focus — so M couldn't be
    ; pressed again without re-focusing via Alt+Y. T never loses focus because it edits in
    ; place. Re-activate after the rebuild to give M the same behavior. (Mirrors a host's popup-
    ; focused hotkey context: #If WinActive the LLM Usage Monitor window.)
    wasActive := (usageMonitorVisible && usageMonitorHwnd && WinActive("ahk_id " . usageMonitorHwnd))

    ; The transient mini resets panel never survives a view change — tear it down up front.
    UsageMonitorHideMiniResetsPanel()

    wasMiniMode := (usageMonitorViewMode = "mini")
    usageMonitorViewMode := wasMiniMode ? "full" : "mini"
    if (wasMiniMode && usageMonitorViewMode = "full")
    {
        usageMonitorTransparencyHoldUntilLeave := true
        usageMonitorTransparencyHoldSawInside := false
    }
    else
    {
        usageMonitorTransparencyHoldUntilLeave := false
        usageMonitorTransparencyHoldSawInside := false
    }
    UsageMonitorPersistViewMode()
    UsageMonitorSetPassthrough(false)

    ; Destroying + recreating the GUI briefly surfaces whatever window is next in z-order
    ; (often VS Code). Suppress anchor capture across the rebuild so the overlay keeps
    ; anchoring to the last-focused tracked window instead of grabbing that transient.
    usageMonitorSuppressAnchorCapture := true

    if (usageMonitorGuiReady)
    {
        Gui, UsageMon:Destroy
        usageMonitorGuiReady := false
        usageMonitorHwnd := 0
    }

    if (usageMonitorVisible)
    {
        UsageMonitorEnsureGui()
        UsageMonitorSetError("")
        if (IsObject(usageMonitorLastSnapshot))
            UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
        Gui, UsageMon:Show, AutoSize NoActivate, LLM Usage Monitor
        UsageMonitorScheduleSpriteBuild()
        UsageMonitorApplyAnchor()
        UsageMonitorUpdatePassthrough()
        SetTimer, UsageMonitorFocusBorderCheck, 200
        if (wasActive && usageMonitorHwnd)
        {
            WinActivate, ahk_id %usageMonitorHwnd%
            WinWaitActive, ahk_id %usageMonitorHwnd%, , 1
        }
    }

    usageMonitorSuppressAnchorCapture := false
}

; Flip the color theme (default <-> cyberpunk), persist it, and rebuild the GUI so the build's
; UsageMonitorApplyTheme() pass recolors everything. Same destroy/recreate path as the view
; toggle, but the view mode is unchanged.
UsageMonitorToggleTheme()
{
    global usageMonitorTheme

    usageMonitorTheme := (usageMonitorTheme = "cyberpunk") ? "default" : "cyberpunk"
    UsageMonitorPersistTheme()
    UsageMonitorRebuildPopup()
}

; Rebuild the popup when the per-model (Fable) row's presence flips between snapshots: the
; full view builds that row conditionally, and AHK statics never reflow around a hidden
; control, so hide/show cannot reclaim or open the row's space. Same destroy/recreate path
; as the theme toggle. Callers must update usageMonitorClaudeFableActive FIRST — the nested
; ApplySnapshot below then matches the rebuilt layout and cannot re-trigger this.
UsageMonitorRebuildForFableChange()
{
    UsageMonitorRebuildPopup()
}

; Destroy and rebuild a visible popup in place (theme, Fable row, Settings), re-applying the last
; snapshot and giving focus back if it had it. False when there is no visible popup to rebuild;
; a hidden one is rebuilt on its next show (UsageMonitorApplyUiScale).
UsageMonitorRebuildPopup()
{
    global usageMonitorGuiReady, usageMonitorVisible, usageMonitorHwnd
    global usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus, usageMonitorSuppressAnchorCapture

    if (!usageMonitorVisible || !usageMonitorGuiReady || !usageMonitorHwnd)
        return false

    wasActive := WinActive("ahk_id " . usageMonitorHwnd)
    UsageMonitorHideMiniResetsPanel()
    usageMonitorSuppressAnchorCapture := true

    Gui, UsageMon:Destroy
    usageMonitorGuiReady := false
    usageMonitorHwnd := 0

    UsageMonitorEnsureGui()
    UsageMonitorSetError("")
    if (IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
    Gui, UsageMon:Show, AutoSize NoActivate, LLM Usage Monitor
    UsageMonitorScheduleSpriteBuild()
    UsageMonitorApplyAnchor()
    UsageMonitorUpdatePassthrough()
    if (wasActive && usageMonitorHwnd)
    {
        WinActivate, ahk_id %usageMonitorHwnd%
        WinWaitActive, ahk_id %usageMonitorHwnd%, , 1
    }
    usageMonitorSuppressAnchorCapture := false
    return true
}

; Settings changed the anchor mode: a shown (or parked) popup closes and reopens in the new mode,
; parking if docking finds no tracked app. A closed popup simply opens in it next time.
UsageMonitorReopenForAnchorChange()
{
    global usageMonitorVisible, usageMonitorParked, usageMonitorGuiReady, usageMonitorHwnd

    UsageMonitorLoadAnchorMode()
    if (!usageMonitorVisible && !usageMonitorParked)
        return
    HideUsageMonitorPopup(true)
    if (usageMonitorGuiReady)
    {
        Gui, UsageMon:Destroy
        usageMonitorGuiReady := false
        usageMonitorHwnd := 0
    }
    if (!ShowUsageMonitorPopup(true))
        UsageMonitorParkPopup()
}

UsageMonitorResetControlState()
{
    global usageMonitorCtrlColors, usageMonitorCtrlBgColors, usageMonitorButtons
    global usageMonitorButtonGroups, usageMonitorButtonHoverGroup, usageMonitorButtonPressedGroup
    global usageMonitorHwndRefreshBtn, usageMonitorHwndViewToggleBtn, usageMonitorHwndThemeBtn
    global usageMonitorHwndResetToggleBtn, usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndCodexHeader, usageMonitorHwndClaudeHeader, usageMonitorHwndClaudeAccount
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar, usageMonitorHwndMiniDivider
    global usageMonitorHwndClaudeFable, usageMonitorHwndClaudeFableBar
    global usageMonitorClaudeFableActive, usageMonitorBuiltClaudeFable
    global usageMonitorHwndGrokHeader, usageMonitorHwndGrokMonthly, usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndMiniDivider2
    global usageMonitorHwndMiniHideCodex, usageMonitorHwndMiniHideClaude, usageMonitorHwndMiniHideGrok
    global usageMonitorHwndCodexMiniToggle, usageMonitorHwndClaudeMiniToggle, usageMonitorHwndGrokMiniToggle
    global usageMonitorHwndAddonHeader, usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar, usageMonitorHwndAddonMiniToggle
    global usageMonitorHwndMiniHideAddon, usageMonitorHwndMiniDivider3
    global usageMonitorHwndSprite, usageMonitorHwndSpritePlaceholder, usageMonitorSpritePath
    global usageMonitorHwndLoginHint, usageMonitorHwndHelp
    global usageMonitorHwndDragHandle, usageMonitorHwndCloseBtn, usageMonitorCloseBtnShown
    global usageMonitorPassthroughActive, usageMonitorWindowAlpha, usageMonitorWindowAlphaHwnd
    global usageMonitorLastCtrlText, usageMonitorLastBarState, usageMonitorMiniLayoutKey
    global usageMonitorSpriteApplied, usageMonitorLoginHintCollapsed, usageMonitorLastAccountDisplay
    global usageMonitorHwndCodexSource, usageMonitorHwndGrokSource, usageMonitorHwndAddonSource

    usageMonitorCtrlColors := {}
    usageMonitorCtrlBgColors := {}
    ; The rebuild recreates every control, so nothing the change gates remember is
    ; true of the new ones. Clearing here forces the next snapshot to write in full.
    usageMonitorLastCtrlText := {}
    usageMonitorLastBarState := {}
    usageMonitorMiniLayoutKey := ""
    usageMonitorSpriteApplied := 0
    usageMonitorLoginHintCollapsed := false
    usageMonitorLastAccountDisplay := ""
    usageMonitorButtons := {}
    usageMonitorButtonGroups := {}
    usageMonitorButtonHoverGroup := ""
    usageMonitorButtonPressedGroup := ""
    UsageMonitorHideHoverTooltip()
    usageMonitorPassthroughActive := false
    usageMonitorWindowAlpha := ""
    usageMonitorWindowAlphaHwnd := 0
    usageMonitorHwndRefreshBtn := 0
    usageMonitorHwndViewToggleBtn := 0
    usageMonitorHwndThemeBtn := 0
    usageMonitorHwndResetToggleBtn := 0
    usageMonitorHwndCodexHeader := 0
    usageMonitorHwndCodexSource := 0
    usageMonitorHwndGrokSource := 0
    usageMonitorHwndAddonSource := 0
    usageMonitorHwndCodexDaily := 0
    usageMonitorHwndCodexWeekly := 0
    usageMonitorHwndClaudeHeader := 0
    usageMonitorHwndClaudeAccount := 0
    usageMonitorHwndClaudeDaily := 0
    usageMonitorHwndClaudeWeekly := 0
    usageMonitorHwndCodexDailyBar := 0
    usageMonitorHwndCodexWeeklyBar := 0
    usageMonitorHwndClaudeDailyBar := 0
    usageMonitorHwndClaudeWeeklyBar := 0
    usageMonitorHwndClaudeFable := 0
    usageMonitorHwndClaudeFableBar := 0
    usageMonitorHwndGrokHeader := 0
    usageMonitorHwndGrokMonthly := 0
    usageMonitorHwndGrokMonthlyBar := 0
    usageMonitorHwndMiniDivider := 0
    usageMonitorHwndMiniDivider2 := 0
    usageMonitorHwndCodexMiniToggle := 0
    usageMonitorHwndClaudeMiniToggle := 0
    usageMonitorHwndGrokMiniToggle := 0
    usageMonitorHwndMiniHideCodex := 0
    usageMonitorHwndMiniHideClaude := 0
    usageMonitorHwndMiniHideGrok := 0
    usageMonitorHwndAddonHeader := 0
    usageMonitorHwndAddonLine1 := 0
    usageMonitorHwndAddonLine2 := 0
    usageMonitorHwndAddonLine1Bar := 0
    usageMonitorHwndAddonLine2Bar := 0
    usageMonitorHwndAddonMiniToggle := 0
    usageMonitorHwndMiniHideAddon := 0
    usageMonitorHwndMiniDivider3 := 0
    usageMonitorHwndSprite := 0
    usageMonitorHwndSpritePlaceholder := 0
    usageMonitorSpritePath := ""
    usageMonitorHwndLoginHint := 0
    usageMonitorHwndHelp := 0
    usageMonitorHwndDragHandle := 0
    usageMonitorHwndCloseBtn := 0
    usageMonitorCloseBtnShown := false
}

; Build the popup for the current view mode. MUST run to completion as one atomic thread:
; usageMonitorGuiReady only flips true on the LAST line, so until then nothing stops a second
; thread (Alt+Y arriving mid-build, a timer that shows/rebuilds the popup, a theme/view toggle
; hotkey) from entering here again. That second build's `Gui, UsageMon:New` destroys the
; half-finished window and recreates every control; when the interrupted first build resumes it
; keeps adding controls into the NEW window and dies on the first variable the rebuild already
; bound — "The same variable cannot be used for more than one control", pointing at whatever
; arbitrary line it happened to be on (vUsageMonMiniHideClaude in the reported crash).
; Two layers: Critical makes the build uninterruptible, and usageMonitorGuiBuilding rejects any
; re-entry Critical cannot stop. Both must be cleared on EVERY exit path.
UsageMonitorEnsureGui()
{
    global usageMonitorGuiBuilding
    global usageMonitorGuiReady, usageMonitorHwnd, usageMonitorUiScale, usageMonitorUiFontScale, usageMonitorBuiltUiScale
    global usageMonitorBuiltViewMode, usageMonitorViewMode
    global usageMonitorCtrlColors, usageMonitorBgBrush
    global usageMonitorHwndCodexHeader, usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndClaudeHeader, usageMonitorHwndClaudeAccount
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar, usageMonitorHwndMiniDivider
    global usageMonitorHwndClaudeFable, usageMonitorHwndClaudeFableBar
    global usageMonitorClaudeFableActive, usageMonitorBuiltClaudeFable
    global usageMonitorHwndGrokHeader, usageMonitorHwndGrokMonthly, usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndMiniDivider2
    global usageMonitorHwndCodexMiniToggle, usageMonitorHwndClaudeMiniToggle, usageMonitorHwndGrokMiniToggle
    global usageMonitorHwndMiniHideCodex, usageMonitorHwndMiniHideClaude, usageMonitorHwndMiniHideGrok
    global UsageMonGrokHeader, UsageMonGrokMonthly, UsageMonGrokMonthlyBar, UsageMonMiniDivider2
    global usageMonitorHwndAddonHeader, usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar, usageMonitorHwndAddonMiniToggle
    global UsageMonAddonHeader, UsageMonAddonLine1, UsageMonAddonLine2, UsageMonAddonLine1Bar, UsageMonAddonLine2Bar
    global UsageMonAddonMiniToggle
    global UsageMonCodexHeader, UsageMonCodexDaily, UsageMonCodexWeekly
    global UsageMonMiniDivider
    global UsageMonClaudeHeader, UsageMonClaudeAccount, UsageMonClaudeDaily, UsageMonClaudeWeekly, UsageMonClaudeFable
    global UsageMonClaudeAccountToggle
    global UsageMonCodexMiniToggle, UsageMonClaudeMiniToggle, UsageMonGrokMiniToggle
    global UsageMonMiniHideCodex, UsageMonMiniHideClaude, UsageMonMiniHideGrok
    global usageMonitorHwndClaudeAccountToggle, usageMonitorHwndClaudeAccountSignal
    global UsageMonCodexDailyBar, UsageMonCodexWeeklyBar
    global UsageMonClaudeDailyBar, UsageMonClaudeWeeklyBar
    global UsageMonClaudeFable, UsageMonClaudeFableBar
    global UsageMonError, UsageMonLoginHint, UsageMonHelp, UsageMonRefreshBtn, UsageMonSpriteCtrl
    global UsageMonSpritePlaceholder, hwndTmp
    global UsageMonViewToggleBtn, UsageMonResetToggleBtn, UsageMonThemeBtn
    global UsageMonDragHandle, UsageMonCloseBtn
    global usageMonitorHwndRefreshBtn, usageMonitorHwndViewToggleBtn, usageMonitorHwndResetToggleBtn
    global usageMonitorHwndThemeBtn
    global usageMonitorFooterBaseYHelp, usageMonitorFooterBaseYRefresh, usageMonitorFooterBaseYResets
    global usageMonitorLoginHintBaseY, usageMonitorErrorShownHeight
    global usageMonitorHwndCodexHeader, usageMonitorHwndClaudeHeader, usageMonitorHwndClaudeAccount
    global usageMonitorHwndLoginHint, usageMonitorHwndHelp, usageMonitorHwndSprite
    global usageMonitorHwndSpritePlaceholder, usageMonitorSpritePath, usageMonitorSpriteFile
    global usageMonitorHwndDragHandle, usageMonitorHwndCloseBtn
    global usageMonitorHwndCodexSource, usageMonitorHwndGrokSource, usageMonitorHwndAddonSource
    global UsageMonCodexSource, UsageMonGrokSource, UsageMonAddonSource
    global usageMonitorBuiltTheme, usageMonitorTheme
    global usageMonitorAddonActive

    if (usageMonitorGuiReady || usageMonitorGuiBuilding)
        return

    prevCritical := A_IsCritical
    Critical
    usageMonitorGuiBuilding := true

    UsageMonitorResetControlState()
    ; MaxThreads 8 (AHK's default is 1). WM_CTLCOLORSTATIC is sent rather than posted, so it
    ; can never be buffered: with a cap of 1, a nested send while the monitor is mid-flight is
    ; silently discarded and that control falls back to its build-time color. Allowing re-entry
    ; services those instead. Safe because the handler is stateless — it touches only the DC
    ; and the control HWND it was handed — so out-of-order execution changes nothing.
    OnMessage(0x0138, "UsageMonCTLColorStatic", 8)
    OnMessage(0x0202, "UsageMonWM_LBUTTONUP")
    OnMessage(0x0200, "UsageMonWM_MOUSEMOVE")
    OnMessage(0x0201, "UsageMonWM_LBUTTONDOWN")  ; WM_LBUTTONDOWN  — drag initiation
    OnMessage(0x0231, "UsageMonWM_ENTERSIZEMOVE") ; WM_ENTERSIZEMOVE — pause anchor during drag
    OnMessage(0x0232, "UsageMonWM_EXITSIZEMOVE") ; WM_EXITSIZEMOVE — record offset after drag
    OnMessage(0x0020, "UsageMonWM_SETCURSOR")    ; WM_SETCURSOR    — cursor on drag handle hover
    OnMessage(0x0006, "UsageMonWM_ACTIVATE")     ; WM_ACTIVATE     — focus on the popup wakes a sleeping idle tier

    ; -DPIScale: the popup runs in ONE coordinate space (raw physical pixels). AHK's default
    ; DPIScale multiplies Gui coords by A_ScreenDPI/96 while WinGetPos/MouseGetPos stay physical,
    ; which silently breaks every measured-position computation (sprite, reflow, hit-zones) on
    ; any system DPI above 96. UsScale/UsFont own all scaling explicitly instead.
    Gui, UsageMon:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorHwnd, LLM Usage Monitor
    Gui, UsageMon:Color, % UsageMonitorThemeRgb("bg"), % UsageMonitorThemeRgb("bg")

    if (usageMonitorViewMode = "mini")
    {
        UsageMonitorBuildMiniGui()
        usageMonitorGuiBuilding := false
        Critical, %prevCritical%
        return
    }

    Gui, UsageMon:Margin, % UsScale(10), % UsScale(6)

    ; Drag handle (top-left) + theme / mini / close packed to the top-right.
    Gui, UsageMon:Font, % "s" . UsFont(8) . " c" . UsageMonitorThemeRgb("drag"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . UsScale(3) . " y" . UsScale(3) . " w" . UsScale(18) . " h" . UsScale(13) . " Center gUsageMonDragHandle vUsageMonDragHandle", ::
    Gui, UsageMon:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("text") . " Bold", Segoe UI
    Gui, UsageMon:Add, Text, % "x" . UsScale(262) . " y" . UsScale(2) . " w" . UsScale(16) . " h" . UsScale(14) . " Center 0x200 Border gUsageMonBtnToggleView vUsageMonViewToggleBtn", -
    ; Theme toggle (palette glyph) — switches Default <-> Cyberpunk colors; mirrors the `C` hotkey.
    Gui, UsageMon:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("text"), Segoe UI Emoji
    Gui, UsageMon:Add, Text, % "x" . UsScale(242) . " y" . UsScale(2) . " w" . UsScale(16) . " h" . UsScale(14) . " Center 0x200 Border gUsageMonBtnToggleTheme vUsageMonThemeBtn", % Chr(0x1F3A8)
    Gui, UsageMon:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("close") . " Bold", Segoe UI
    Gui, UsageMon:Add, Text, % "x" . UsScale(282) . " y" . UsScale(2) . " w" . UsScale(16) . " h" . UsScale(14) . " Center 0x200 Border gUsageMonBtnClose vUsageMonCloseBtn", X

    ; Codex section. The header is as wide as its word; the dim source tag after it (CLI /
    ; Firefox, see UsageMonitorUpdateSourceTags) fills the rest of the old 180px header slot, so
    ; the mini toggle keeps its position and the window its width.
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Bold Underline c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm ym+" . UsScale(14) . " gUsageMonBtnOpenCodex vUsageMonCodexHeader w" . UsScale(45), Codex
    Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm c" . UsageMonitorThemeRgb("dim"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp+" . UsScale(1) . " w" . UsScale(131) . " h" . UsScale(15) . " vUsageMonCodexSource",
    Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp-" . UsScale(1) . " w" . UsScale(96) . " h" . UsScale(16) . " Center 0x200 Border gUsageMonBtnToggleMiniCodex vUsageMonCodexMiniToggle", Mini: Auto-hidden
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(3) . " vUsageMonCodexDaily w" . UsScale(280), Daily: -
    Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonCodexDailyBar", 0
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(4) . " vUsageMonCodexWeekly w" . UsScale(280), Weekly: -
    Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonCodexWeeklyBar", 0

    ; Claude section
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Bold Underline c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(10) . " gUsageMonBtnOpenClaude vUsageMonClaudeHeader w" . UsScale(45), Claude
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp w" . UsScale(104) . " h" . UsScale(16) . " gUsageMonBtnSwitchClaudeAccount vUsageMonClaudeAccount",
    GuiControl, UsageMon:Hide, UsageMonClaudeAccount
    ; Eye glyph: independent hide/show toggle for the account label (always visible; it is the handle)
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI Emoji
    Gui, UsageMon:Add, Text, % "x+4 yp w" . UsScale(18) . " h" . UsScale(16) . " Center gUsageMonBtnToggleClaudeAccount vUsageMonClaudeAccountToggle",
    Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp w" . UsScale(96) . " h" . UsScale(16) . " Center 0x200 Border gUsageMonBtnToggleMiniClaude vUsageMonClaudeMiniToggle", Mini: Auto-hidden
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(3) . " vUsageMonClaudeDaily w" . UsScale(280), Daily: -
    Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonClaudeDailyBar", 0
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(4) . " vUsageMonClaudeWeekly w" . UsScale(280), Weekly: -
    Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonClaudeWeeklyBar", 0
    ; Per-model scoped weekly meter (claude_line_3, e.g. "Fable: 87% remaining"). Built only
    ; when the snapshot carries the line; presence flips trigger a destroy+rebuild in
    ; UsageMonitorApplySnapshot because AHK statics never reflow around a hidden control.
    if (usageMonitorClaudeFableActive)
    {
        Gui, UsageMon:Add, Text, % "xm y+" . UsScale(4) . " vUsageMonClaudeFable w" . UsScale(280), Fable: -
        Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonClaudeFableBar", 0
    }

    ; Grok section (single weekly Grok Build usage window)
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Bold Underline c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(10) . " gUsageMonBtnOpenGrokHeader vUsageMonGrokHeader w" . UsScale(45), Grok
    Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm c" . UsageMonitorThemeRgb("dim"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp+" . UsScale(1) . " w" . UsScale(131) . " h" . UsScale(15) . " vUsageMonGrokSource",
    Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x+4 yp-" . UsScale(1) . " w" . UsScale(96) . " h" . UsScale(16) . " Center 0x200 Border gUsageMonBtnToggleMiniGrok vUsageMonGrokMiniToggle", Mini: Auto-hidden
    Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(3) . " gUsageMonBtnOpenGrok vUsageMonGrokMonthly w" . UsScale(280), Weekly: -
    Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonGrokMonthlyBar", 0

    ; Add-on section (a host-named provider module, addon-provider.mjs: two rows). Built only
    ; when the host set usageMonitorHostAddonModule; the standalone app never has it.
    if (usageMonitorAddonActive)
    {
        Gui, UsageMon:Font, % "s" . UsFont(9) . " Bold Underline c" . UsageMonitorThemeRgb("header"), Segoe UI
        Gui, UsageMon:Add, Text, % "xm y+" . UsScale(10) . " gUsageMonBtnOpenAddonHeader vUsageMonAddonHeader w" . UsScale(48), % UsageMonitorAddonDisplayLabel()
        Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm c" . UsageMonitorThemeRgb("dim"), Segoe UI
        Gui, UsageMon:Add, Text, % "x+4 yp+" . UsScale(1) . " w" . UsScale(128) . " h" . UsScale(15) . " vUsageMonAddonSource",
        Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
        Gui, UsageMon:Add, Text, % "x+4 yp-" . UsScale(1) . " w" . UsScale(96) . " h" . UsScale(16) . " Center 0x200 Border gUsageMonBtnToggleMiniAddon vUsageMonAddonMiniToggle", Mini: Auto-hidden
        Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
        Gui, UsageMon:Add, Text, % "xm y+" . UsScale(3) . " vUsageMonAddonLine1 w" . UsScale(280), -
        Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonAddonLine1Bar", 0
        Gui, UsageMon:Add, Text, % "xm y+" . UsScale(4) . " vUsageMonAddonLine2 w" . UsScale(280), -
        Gui, UsageMon:Add, Progress, % "xm y+" . UsScale(2) . " w" . UsScale(280) . " h" . UsScale(6) . " Background2D2D2D Range0-100 vUsageMonAddonLine2Bar", 0
    }

    ; Error/status starts at 1px tall to collapse the gap when empty. Provider headers
    ; own sign-in links; the hidden Text stub avoids native Link colors that ignore themes.
    Gui, UsageMon:Font, % "s" . UsFont(8) . " c" . UsageMonitorThemeRgb("bad"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(2) . " vUsageMonError w" . UsScale(280) . " h" . UsScale(1),
    Gui, UsageMon:Font, % "s" . UsFont(8) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(0) . " vUsageMonLoginHint w" . UsScale(280) . " h" . UsScale(1),
    GuiControl, UsageMon:Hide, UsageMonLoginHint

    ; Footer controls stay in the left column so they do not drift into the sprite.
    Gui, UsageMon:Font, % "s" . UsFont(8) . " c" . UsageMonitorThemeRgb("hint"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(2) . " vUsageMonHelp w" . UsScale(170) . " h" . UsScale(98) . " Section", [Esc] - Close`n[R] - Reload`n[T] - Resets`n[M] - Toggle Mini Gui`n[S] - Switch Account`n[A] - Hide/Show Account`n[O] - Settings
    Gui, UsageMon:Font, % "s" . UsFont(8) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "xm y+" . UsScale(4) . " w" . UsScale(80) . " h" . UsScale(20) . " Center Border gUsageMonBtnRefresh vUsageMonRefreshBtn", Refresh
    Gui, UsageMon:Add, Text, % "x+8 yp w" . UsScale(80) . " h" . UsScale(20) . " Center Border gUsageMonBtnToggleResets vUsageMonResetToggleBtn", Resets

    ; Animated sprite GIF (bottom-right corner), only when the host names one
    ; (usageMonitorHostSpriteFile). Displayed via Shell.Explorer <img> — no Canvas, no registry,
    ; no special IE mode.
    spriteGifFile := usageMonitorSpriteFile
    spriteGifAbsPath := ""
    if (spriteGifFile != "")
    {
        VarSetCapacity(spriteGifAbsPath, 520)
        DllCall("GetFullPathName", "Str", spriteGifFile, "UInt", 260, "Str", spriteGifAbsPath, "Ptr", 0)
    }
    if (spriteGifAbsPath != "" && FileExist(spriteGifAbsPath))
    {
        usageMonitorSpritePath := spriteGifAbsPath
        Gui, UsageMon:Add, Text, % "x" . UsScale(170) . " y" . UsScale(120) . " w" . UsScale(120) . " h" . UsScale(95) . " vUsageMonSpritePlaceholder HwndusageMonitorHwndSpritePlaceholder",
    }

    ; Capture text control HWNDs for WM_CTLCOLORSTATIC
    GuiControlGet, usageMonitorHwndCodexHeader, UsageMon:Hwnd, UsageMonCodexHeader
    usageMonitorCtrlColors[usageMonitorHwndCodexHeader] := 0xD69C56
    ; Source tags: the "dim" role's Default literal (0x909090), remapped by UsageMonitorApplyTheme.
    GuiControlGet, usageMonitorHwndCodexSource, UsageMon:Hwnd, UsageMonCodexSource
    GuiControlGet, usageMonitorHwndGrokSource, UsageMon:Hwnd, UsageMonGrokSource
    if (usageMonitorAddonActive)
        GuiControlGet, usageMonitorHwndAddonSource, UsageMon:Hwnd, UsageMonAddonSource
    GuiControlGet, usageMonitorHwndCodexMiniToggle, UsageMon:Hwnd, UsageMonCodexMiniToggle
    usageMonitorCtrlColors[usageMonitorHwndCodexMiniToggle] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndCodexDaily, UsageMon:Hwnd, UsageMonCodexDaily
    usageMonitorCtrlColors[usageMonitorHwndCodexDaily] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndCodexWeekly, UsageMon:Hwnd, UsageMonCodexWeekly
    usageMonitorCtrlColors[usageMonitorHwndCodexWeekly] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeHeader, UsageMon:Hwnd, UsageMonClaudeHeader
    usageMonitorCtrlColors[usageMonitorHwndClaudeHeader] := 0xD69C56
    GuiControlGet, usageMonitorHwndClaudeAccount, UsageMon:Hwnd, UsageMonClaudeAccount
    usageMonitorCtrlColors[usageMonitorHwndClaudeAccount] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeAccountToggle, UsageMon:Hwnd, UsageMonClaudeAccountToggle
    usageMonitorCtrlColors[usageMonitorHwndClaudeAccountToggle] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeMiniToggle, UsageMon:Hwnd, UsageMonClaudeMiniToggle
    usageMonitorCtrlColors[usageMonitorHwndClaudeMiniToggle] := 0xD4D4D4
    usageMonitorHwndClaudeAccountSignal := 0
    GuiControlGet, usageMonitorHwndClaudeDaily, UsageMon:Hwnd, UsageMonClaudeDaily
    usageMonitorCtrlColors[usageMonitorHwndClaudeDaily] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeWeekly, UsageMon:Hwnd, UsageMonClaudeWeekly
    usageMonitorCtrlColors[usageMonitorHwndClaudeWeekly] := 0xD4D4D4
    if (usageMonitorClaudeFableActive)
    {
        GuiControlGet, usageMonitorHwndClaudeFable, UsageMon:Hwnd, UsageMonClaudeFable
        usageMonitorCtrlColors[usageMonitorHwndClaudeFable] := 0xD4D4D4
    }
    GuiControlGet, usageMonitorHwndGrokHeader, UsageMon:Hwnd, UsageMonGrokHeader
    usageMonitorCtrlColors[usageMonitorHwndGrokHeader] := 0xD69C56
    GuiControlGet, usageMonitorHwndGrokMiniToggle, UsageMon:Hwnd, UsageMonGrokMiniToggle
    usageMonitorCtrlColors[usageMonitorHwndGrokMiniToggle] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndGrokMonthly, UsageMon:Hwnd, UsageMonGrokMonthly
    usageMonitorCtrlColors[usageMonitorHwndGrokMonthly] := 0xD4D4D4
    ; Only real hwnds get a colour key: a blank key makes UsageMonitorApplyTheme invalidate NULL,
    ; which repaints every window on the desktop.
    if (usageMonitorAddonActive)
    {
        GuiControlGet, usageMonitorHwndAddonHeader, UsageMon:Hwnd, UsageMonAddonHeader
        usageMonitorCtrlColors[usageMonitorHwndAddonHeader] := 0xD69C56
        GuiControlGet, usageMonitorHwndAddonMiniToggle, UsageMon:Hwnd, UsageMonAddonMiniToggle
        usageMonitorCtrlColors[usageMonitorHwndAddonMiniToggle] := 0xD4D4D4
        GuiControlGet, usageMonitorHwndAddonLine1, UsageMon:Hwnd, UsageMonAddonLine1
        usageMonitorCtrlColors[usageMonitorHwndAddonLine1] := 0xD4D4D4
        GuiControlGet, usageMonitorHwndAddonLine2, UsageMon:Hwnd, UsageMonAddonLine2
        usageMonitorCtrlColors[usageMonitorHwndAddonLine2] := 0xD4D4D4
    }
    GuiControlGet, hwndTmp, UsageMon:Hwnd, UsageMonError
    usageMonitorCtrlColors[hwndTmp] := 0x4747F4
    GuiControlGet, usageMonitorHwndHelp, UsageMon:Hwnd, UsageMonHelp
    usageMonitorCtrlColors[usageMonitorHwndHelp] := 0x8A8A8A
    GuiControlGet, usageMonitorHwndRefreshBtn, UsageMon:Hwnd, UsageMonRefreshBtn
    usageMonitorCtrlColors[usageMonitorHwndRefreshBtn] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndViewToggleBtn, UsageMon:Hwnd, UsageMonViewToggleBtn
    usageMonitorCtrlColors[usageMonitorHwndViewToggleBtn] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndResetToggleBtn, UsageMon:Hwnd, UsageMonResetToggleBtn
    GuiControlGet, usageMonitorHwndLoginHint, UsageMon:Hwnd, UsageMonLoginHint
    GuiControlGet, usageMonitorHwndDragHandle, UsageMon:Hwnd, UsageMonDragHandle
    usageMonitorCtrlColors[usageMonitorHwndDragHandle] := 0x888888
    GuiControlGet, usageMonitorHwndCloseBtn, UsageMon:Hwnd, UsageMonCloseBtn
    usageMonitorCtrlColors[usageMonitorHwndCloseBtn] := 0x5555FF  ; #FF5555 red in BGR
    GuiControlGet, usageMonitorHwndThemeBtn, UsageMon:Hwnd, UsageMonThemeBtn

    ; Footer baselines for the dynamic error-line reflow: when an error/status message is
    ; shown the error control grows and the footer (help + buttons) is pushed down by the
    ; delta so nothing is clipped/overlapped (see UsageMonitorReflowErrorFooter). Captured
    ; here (error built at 1px) so the delta is measured from the collapsed layout.
    GuiControlGet, umFooterHelp, UsageMon:Pos, UsageMonHelp
    GuiControlGet, umFooterRefresh, UsageMon:Pos, UsageMonRefreshBtn
    GuiControlGet, umFooterResets, UsageMon:Pos, UsageMonResetToggleBtn
    GuiControlGet, umLoginHint, UsageMon:Pos, UsageMonLoginHint
    usageMonitorFooterBaseYHelp := umFooterHelpY
    usageMonitorFooterBaseYRefresh := umFooterRefreshY
    usageMonitorFooterBaseYResets := umFooterResetsY
    usageMonitorLoginHintBaseY := umLoginHintY
    usageMonitorErrorShownHeight := 0

    ; pressNudge=false: a 1px press-shift would call GuiControl Move on this static every
    ; hover/press/release, and that runtime re-layout drops its SS_CENTERIMAGE vertical
    ; centering — leaving the +/- looking off-center after the first interaction. Color-only
    ; hover/press feedback still works via WM_CTLCOLORSTATIC.
    UsageMonitorRegisterButton(usageMonitorHwndViewToggleBtn, "UsageMonViewToggleBtn", "view", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    ; pressNudge=false: the 🎨 emoji is centered via SS_CENTERIMAGE (0x200); a press-shift
    ; GuiControl Move would strip that centering (same gotcha as the +/- view toggle).
    UsageMonitorRegisterButton(usageMonitorHwndThemeBtn, "UsageMonThemeBtn", "theme", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndCloseBtn, "UsageMonCloseBtn", "close", 0x5555FF, 0x7777FF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F)
    UsageMonitorRegisterButton(usageMonitorHwndDragHandle, "UsageMonDragHandle", "drag", 0x888888, 0xD4D4D4, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndCodexHeader, "UsageMonCodexHeader", "provider-link-codex", 0xD69C56, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    UsageMonitorRegisterButton(usageMonitorHwndClaudeHeader, "UsageMonClaudeHeader", "provider-link-claude", 0xD69C56, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    UsageMonitorRegisterButton(usageMonitorHwndGrokHeader, "UsageMonGrokHeader", "provider-link-grok", 0xD69C56, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    UsageMonitorRegisterButton(usageMonitorHwndRefreshBtn, "UsageMonRefreshBtn", "refresh")
    UsageMonitorRegisterButton(usageMonitorHwndResetToggleBtn, "UsageMonResetToggleBtn", "resets")
    UsageMonitorRegisterButton(usageMonitorHwndClaudeAccount, "UsageMonClaudeAccount", "claude-account", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndClaudeAccountToggle, "UsageMonClaudeAccountToggle", "claude-account-toggle", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndCodexMiniToggle, "UsageMonCodexMiniToggle", "mini-toggle-codex", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndClaudeMiniToggle, "UsageMonClaudeMiniToggle", "mini-toggle-claude", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndGrokMiniToggle, "UsageMonGrokMiniToggle", "mini-toggle-grok", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    if (usageMonitorAddonActive)
        UsageMonitorRegisterButton(usageMonitorHwndAddonHeader, "UsageMonAddonHeader", "provider-link-addon", 0xD69C56, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    ; Source tags are registered only for their hover tooltip: no click handler, no hover color.
    UsageMonitorRegisterButton(usageMonitorHwndCodexSource, "UsageMonCodexSource", "provider-source-codex", 0x909090, 0x909090, 0x909090, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    UsageMonitorRegisterButton(usageMonitorHwndGrokSource, "UsageMonGrokSource", "provider-source-grok", 0x909090, 0x909090, 0x909090, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
    if (usageMonitorAddonActive)
    {
        UsageMonitorRegisterButton(usageMonitorHwndAddonSource, "UsageMonAddonSource", "provider-source-addon", 0x909090, 0x909090, 0x909090, 0x1E1E1E, 0x1E1E1E, 0x1E1E1E, false)
        UsageMonitorRegisterButton(usageMonitorHwndAddonMiniToggle, "UsageMonAddonMiniToggle", "mini-toggle-addon", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    }

    ; Capture bar HWNDs, remove visual theme so PBM_SETBARCOLOR works, set track color
    GuiControlGet, usageMonitorHwndCodexDailyBar, UsageMon:Hwnd, UsageMonCodexDailyBar
    DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndCodexDailyBar, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndCodexDailyBar%
    GuiControlGet, usageMonitorHwndCodexWeeklyBar, UsageMon:Hwnd, UsageMonCodexWeeklyBar
    DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndCodexWeeklyBar, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndCodexWeeklyBar%
    GuiControlGet, usageMonitorHwndClaudeDailyBar, UsageMon:Hwnd, UsageMonClaudeDailyBar
    DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndClaudeDailyBar, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndClaudeDailyBar%
    GuiControlGet, usageMonitorHwndClaudeWeeklyBar, UsageMon:Hwnd, UsageMonClaudeWeeklyBar
    DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndClaudeWeeklyBar, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndClaudeWeeklyBar%
    if (usageMonitorClaudeFableActive)
    {
        GuiControlGet, usageMonitorHwndClaudeFableBar, UsageMon:Hwnd, UsageMonClaudeFableBar
        DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndClaudeFableBar, "WStr", "", "WStr", "")
        SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndClaudeFableBar%
    }
    GuiControlGet, usageMonitorHwndGrokMonthlyBar, UsageMon:Hwnd, UsageMonGrokMonthlyBar
    DllCall("uxtheme\SetWindowTheme", "Ptr", usageMonitorHwndGrokMonthlyBar, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %usageMonitorHwndGrokMonthlyBar%
    if (usageMonitorAddonActive)
    {
        GuiControlGet, usageMonitorHwndAddonLine1Bar, UsageMon:Hwnd, UsageMonAddonLine1Bar
        UsageMonitorPrepareProgressBar(usageMonitorHwndAddonLine1Bar)
        GuiControlGet, usageMonitorHwndAddonLine2Bar, UsageMon:Hwnd, UsageMonAddonLine2Bar
        UsageMonitorPrepareProgressBar(usageMonitorHwndAddonLine2Bar)
    }


    ; Sprite is decoupled from the help-row Section (which grows with the help text and
    ; previously chopped the GIF). Realize the window size, then pin the sprite to the
    ; bottom-right corner so future layout/line-count changes can never clip it.
    if (usageMonitorHwndSpritePlaceholder)
    {
        prevDetectHidden := A_DetectHiddenWindows
        DetectHiddenWindows, On
        Gui, UsageMon:Show, AutoSize Hide
        UsageMonitorPositionSprite()
        DetectHiddenWindows, %prevDetectHidden%
    }

    usageMonitorGuiReady := true
    usageMonitorBuiltUiScale := usageMonitorUiScale . "|" . usageMonitorUiFontScale
    usageMonitorBuiltViewMode := usageMonitorViewMode
    usageMonitorBuiltTheme := usageMonitorTheme
    usageMonitorBuiltClaudeFable := usageMonitorClaudeFableActive
    UsageMonitorUpdateViewToggleText()
    UsageMonitorUpdateResetToggleText()
    UsageMonitorUpdateClaudeAccountToggleGlyph()
    UsageMonitorUpdateMiniProviderToggleText()
    UsageMonitorApplyTheme()

    usageMonitorGuiBuilding := false
    Critical, %prevCritical%
}

UsageMonitorBuildMiniGui()
{
    global usageMonitorGuiReady, usageMonitorUiScale, usageMonitorUiFontScale, usageMonitorBuiltUiScale
    global usageMonitorBuiltViewMode, usageMonitorViewMode, usageMonitorBuiltTheme, usageMonitorTheme
    global usageMonitorCtrlColors, usageMonitorCtrlBgColors
    global usageMonitorHwndCodexHeader, usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndClaudeHeader, usageMonitorHwndClaudeAccount
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar, usageMonitorHwndMiniDivider
    global usageMonitorHwndClaudeFable, usageMonitorHwndClaudeFableBar
    global usageMonitorClaudeFableActive, usageMonitorBuiltClaudeFable
    global usageMonitorHwndGrokHeader, usageMonitorHwndGrokMonthly, usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndMiniDivider2
    global usageMonitorHwndMiniHideCodex, usageMonitorHwndMiniHideClaude, usageMonitorHwndMiniHideGrok
    global usageMonitorHwndRefreshBtn, usageMonitorHwndViewToggleBtn, usageMonitorHwndResetToggleBtn
    global usageMonitorHwndLoginHint, usageMonitorHwndHelp
    global usageMonitorHwndDragHandle, usageMonitorHwndCloseBtn
    global usageMonitorHwndClaudeAccountToggle, usageMonitorHwndClaudeAccountSignal
    global usageMonitorShowClaudeAccountMini, usageMonitorClaudeAccountShort
    global UsageMonCodexHeader, UsageMonCodexDaily, UsageMonCodexWeekly
    global UsageMonClaudeHeader, UsageMonClaudeAccount, UsageMonClaudeDaily, UsageMonClaudeWeekly, UsageMonClaudeFable
    global UsageMonGrokHeader, UsageMonGrokMonthly, UsageMonMiniDivider2
    global UsageMonMiniHideCodex, UsageMonMiniHideClaude, UsageMonMiniHideGrok
    global usageMonitorHwndAddonHeader, usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar
    global usageMonitorHwndMiniHideAddon, usageMonitorHwndMiniDivider3
    global UsageMonAddonHeader, UsageMonAddonLine1, UsageMonAddonLine2, UsageMonMiniHideAddon, UsageMonMiniDivider3
    global usageMonitorAddonActive
    global UsageMonClaudeAccountSignal
    global UsageMonViewToggleBtn, UsageMonError, UsageMonLoginHint, UsageMonHelp
    global UsageMonRefreshBtn, UsageMonResetToggleBtn, UsageMonDragHandle, UsageMonCloseBtn
    global hwndTmp

    ; Horizontal layout (Codex | Claude | Grok, plus the add-on column when the host has one) at
    ; 10pt, split by vertical bar dividers. Codex/Claude show D:/W: lines; Grok shows a single
    ; Weekly (W:) line; the add-on shows its two rows, abbreviated to their first letter.
    leftX := UsScale(4)
    colW := UsScale(48)
    lineH := UsScale(18)
    dividerX := leftX + colW + UsScale(5)         ; divider 1 (Codex | Claude)
    rightX := dividerX + UsScale(9)               ; Claude column
    divider2X := rightX + colW + UsScale(5)       ; divider 2 (Claude | Grok)
    grokX := divider2X + UsScale(9)               ; Grok column
    divider3X := grokX + colW + UsScale(5)        ; divider 3 (Grok | add-on)
    addonX := divider3X + UsScale(9)              ; add-on column
    ; Right cluster: + on top (yHead), account signal stacked directly beneath it (yDaily),
    ; both at a shared x just past the last column and nudged left toward the values.
    ; UsageMonitorSetMiniProvidersVisible moves it past the last VISIBLE column.
    signalW := UsScale(34)
    ; Past the last column actually built, so a build without an add-on has no gap before it.
    clusterX := (usageMonitorAddonActive ? addonX : grokX) + colW - UsScale(1)
    yHead := UsScale(3)
    yDaily := yHead + lineH
    yWeekly := yDaily + lineH
    yFable := yWeekly + lineH

    ; Defensive: keep the mini rebuild in the same raw-physical-pixel space as the full view
    ; (idempotent — EnsureGui's New already sets it; guards any future direct-call path).
    Gui, UsageMon:-DPIScale
    Gui, UsageMon:Margin, % UsScale(4), % UsScale(3)

    ; Left column: Codex
    Gui, UsageMon:Font, % "s" . UsFont(10) . " Bold c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . leftX . " y" . yHead . " w" . colW . " h" . lineH . " vUsageMonCodexHeader", Codex
    Gui, UsageMon:Font, % "s" . UsFont(10) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . leftX . " y" . yDaily . " w" . colW . " h" . lineH . " vUsageMonCodexDaily", D: -
    Gui, UsageMon:Add, Text, % "x" . leftX . " y" . yWeekly . " w" . colW . " h" . lineH . " vUsageMonCodexWeekly", W: -

    ; Vertical bar divider between the two columns
    Gui, UsageMon:Add, Text, % "x" . dividerX . " y" . yHead . " w" . UsScale(2) . " h" . (lineH * 3) . " HwndusageMonitorHwndMiniDivider vUsageMonMiniDivider",

    ; Right column: Claude
    Gui, UsageMon:Font, % "s" . UsFont(10) . " Bold c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . rightX . " y" . yHead . " w" . colW . " h" . lineH . " vUsageMonClaudeHeader", Claude
    Gui, UsageMon:Font, % "s" . UsFont(10) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . rightX . " y" . yDaily . " w" . colW . " h" . lineH . " vUsageMonClaudeDaily", D: -
    Gui, UsageMon:Add, Text, % "x" . rightX . " y" . yWeekly . " w" . colW . " h" . lineH . " vUsageMonClaudeWeekly", W: -
    ; Per-model scoped weekly row (claude_line_3, e.g. "F:87%"). Hidden until a snapshot
    ; carries the line; UsageMonitorSetMiniProvidersVisible positions and reveals it.
    Gui, UsageMon:Add, Text, % "x" . rightX . " y" . yFable . " w" . colW . " h" . lineH . " vUsageMonClaudeFable", F: -
    GuiControl, UsageMon:Hide, UsageMonClaudeFable

    ; Vertical bar divider between Claude and Grok
    Gui, UsageMon:Add, Text, % "x" . divider2X . " y" . yHead . " w" . UsScale(2) . " h" . (lineH * 3) . " HwndusageMonitorHwndMiniDivider2 vUsageMonMiniDivider2",

    ; Right column: Grok (single Weekly line, placed on the first metric row)
    Gui, UsageMon:Font, % "s" . UsFont(10) . " Bold c" . UsageMonitorThemeRgb("header"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . grokX . " y" . yHead . " w" . colW . " h" . lineH . " vUsageMonGrokHeader", Grok
    Gui, UsageMon:Font, % "s" . UsFont(10) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . grokX . " y" . yDaily . " w" . colW . " h" . lineH . " vUsageMonGrokMonthly", W: -

    if (usageMonitorAddonActive)
    {
        ; Vertical bar divider between Grok and the add-on
        Gui, UsageMon:Add, Text, % "x" . divider3X . " y" . yHead . " w" . UsScale(2) . " h" . (lineH * 3) . " HwndusageMonitorHwndMiniDivider3 vUsageMonMiniDivider3",

        ; Right column: the add-on (two rows)
        Gui, UsageMon:Font, % "s" . UsFont(10) . " Bold c" . UsageMonitorThemeRgb("header"), Segoe UI
        Gui, UsageMon:Add, Text, % "x" . addonX . " y" . yHead . " w" . colW . " h" . lineH . " vUsageMonAddonHeader", % UsageMonitorAddonDisplayLabel()
        Gui, UsageMon:Font, % "s" . UsFont(10) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
        Gui, UsageMon:Add, Text, % "x" . addonX . " y" . yDaily . " w" . colW . " h" . lineH . " vUsageMonAddonLine1", -
        Gui, UsageMon:Add, Text, % "x" . addonX . " y" . yWeekly . " w" . colW . " h" . lineH . " vUsageMonAddonLine2", -
    }

    ; Header-sized Hide overlays are revealed only while the pointer is over a visible
    ; provider column. They reuse header space so the compact HUD never grows for controls.
    Gui, UsageMon:Font, % "s" . UsFont(7) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . leftX . " y" . yHead . " w" . colW . " h" . lineH . " Center 0x200 Border Hidden gUsageMonBtnHideMiniCodex vUsageMonMiniHideCodex", Hide
    Gui, UsageMon:Add, Text, % "x" . rightX . " y" . yHead . " w" . colW . " h" . lineH . " Center 0x200 Border Hidden gUsageMonBtnHideMiniClaude vUsageMonMiniHideClaude", Hide
    Gui, UsageMon:Add, Text, % "x" . grokX . " y" . yHead . " w" . colW . " h" . lineH . " Center 0x200 Border Hidden gUsageMonBtnHideMiniGrok vUsageMonMiniHideGrok", Hide
    if (usageMonitorAddonActive)
        Gui, UsageMon:Add, Text, % "x" . addonX . " y" . yHead . " w" . colW . " h" . lineH . " Center 0x200 Border Hidden gUsageMonBtnHideMiniAddon vUsageMonMiniHideAddon", Hide

    ; Expand (+) toggle, top of the right cluster (just past the Grok column)
    ; Center the glyph on BOTH axes inside the border: "Center" (SS_CENTER) handles horizontal,
    ; "0x200" (SS_CENTERIMAGE) handles vertical — without it the tall "+" is top-aligned and its
    ; lower arm clips. Box matches the full-view toggle (w16 h14) for clear margin all around.
    Gui, UsageMon:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("text") . " Bold", Segoe UI
    Gui, UsageMon:Add, Text, % "x" . clusterX . " y" . yHead . " w" . UsScale(16) . " h" . UsScale(14) . " Center 0x200 Border gUsageMonBtnToggleView vUsageMonViewToggleBtn", +

    ; Account signal: short active-account code (e.g. j42@), stacked directly under the + button;
    ; click toggles its own hide/show
    Gui, UsageMon:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x" . clusterX . " y" . yDaily . " w" . signalW . " h" . lineH . " gUsageMonBtnToggleClaudeAccountMini vUsageMonClaudeAccountSignal",
    GuiControl, UsageMon:Hide, UsageMonClaudeAccountSignal

    Gui, UsageMon:Font, % "s" . UsFont(1) . " c" . UsageMonitorThemeRgb("bad"), Segoe UI
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden vUsageMonError", .
    Gui, UsageMon:Font, % "s" . UsFont(7) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden vUsageMonLoginHint", .
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden gUsageMonBtnRefresh vUsageMonRefreshBtn", .
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden vUsageMonHelp", .
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden gUsageMonBtnToggleResets vUsageMonResetToggleBtn", .
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden gUsageMonDragHandle vUsageMonDragHandle", .
    Gui, UsageMon:Add, Text, % "x0 y0 w" . UsScale(1) . " h" . UsScale(1) . " Hidden gUsageMonBtnClose vUsageMonCloseBtn", X

    ; Store this in its own global, not the shared hwndTmp scratch: Claude's and Grok's mini
    ; headers get proper globals, and leaving usageMonitorHwndCodexHeader at 0 for a whole mini
    ; session means any code that reads it silently no-ops for Codex alone. Harmless today (its
    ; only readers, WM_SETCURSOR and UpdatePassthrough, both return early in mini view) but a
    ; trap for the next mini feature that touches provider headers.
    GuiControlGet, usageMonitorHwndCodexHeader, UsageMon:Hwnd, UsageMonCodexHeader
    usageMonitorCtrlColors[usageMonitorHwndCodexHeader] := 0xD69C56
    GuiControlGet, usageMonitorHwndCodexDaily, UsageMon:Hwnd, UsageMonCodexDaily
    usageMonitorCtrlColors[usageMonitorHwndCodexDaily] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndCodexWeekly, UsageMon:Hwnd, UsageMonCodexWeekly
    usageMonitorCtrlColors[usageMonitorHwndCodexWeekly] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeHeader, UsageMon:Hwnd, UsageMonClaudeHeader
    usageMonitorCtrlColors[usageMonitorHwndClaudeHeader] := 0xD69C56
    usageMonitorHwndClaudeAccount := 0
    usageMonitorHwndClaudeAccountToggle := 0
    GuiControlGet, usageMonitorHwndClaudeAccountSignal, UsageMon:Hwnd, UsageMonClaudeAccountSignal
    usageMonitorCtrlColors[usageMonitorHwndClaudeAccountSignal] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeDaily, UsageMon:Hwnd, UsageMonClaudeDaily
    usageMonitorCtrlColors[usageMonitorHwndClaudeDaily] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeWeekly, UsageMon:Hwnd, UsageMonClaudeWeekly
    usageMonitorCtrlColors[usageMonitorHwndClaudeWeekly] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndClaudeFable, UsageMon:Hwnd, UsageMonClaudeFable
    usageMonitorCtrlColors[usageMonitorHwndClaudeFable] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndGrokHeader, UsageMon:Hwnd, UsageMonGrokHeader
    usageMonitorCtrlColors[usageMonitorHwndGrokHeader] := 0xD69C56
    GuiControlGet, usageMonitorHwndGrokMonthly, UsageMon:Hwnd, UsageMonGrokMonthly
    usageMonitorCtrlColors[usageMonitorHwndGrokMonthly] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndMiniHideCodex, UsageMon:Hwnd, UsageMonMiniHideCodex
    usageMonitorCtrlColors[usageMonitorHwndMiniHideCodex] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndMiniHideClaude, UsageMon:Hwnd, UsageMonMiniHideClaude
    usageMonitorCtrlColors[usageMonitorHwndMiniHideClaude] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndMiniHideGrok, UsageMon:Hwnd, UsageMonMiniHideGrok
    usageMonitorCtrlColors[usageMonitorHwndMiniHideGrok] := 0xD4D4D4
    if (usageMonitorAddonActive)
    {
        GuiControlGet, usageMonitorHwndAddonHeader, UsageMon:Hwnd, UsageMonAddonHeader
        usageMonitorCtrlColors[usageMonitorHwndAddonHeader] := 0xD69C56
        GuiControlGet, usageMonitorHwndAddonLine1, UsageMon:Hwnd, UsageMonAddonLine1
        usageMonitorCtrlColors[usageMonitorHwndAddonLine1] := 0xD4D4D4
        GuiControlGet, usageMonitorHwndAddonLine2, UsageMon:Hwnd, UsageMonAddonLine2
        usageMonitorCtrlColors[usageMonitorHwndAddonLine2] := 0xD4D4D4
        GuiControlGet, usageMonitorHwndMiniHideAddon, UsageMon:Hwnd, UsageMonMiniHideAddon
        usageMonitorCtrlColors[usageMonitorHwndMiniHideAddon] := 0xD4D4D4
    }
    GuiControlGet, hwndTmp, UsageMon:Hwnd, UsageMonError
    usageMonitorCtrlColors[hwndTmp] := 0x4747F4
    GuiControlGet, usageMonitorHwndHelp, UsageMon:Hwnd, UsageMonHelp
    usageMonitorCtrlColors[usageMonitorHwndHelp] := 0x8A8A8A
    GuiControlGet, usageMonitorHwndRefreshBtn, UsageMon:Hwnd, UsageMonRefreshBtn
    usageMonitorCtrlColors[usageMonitorHwndRefreshBtn] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndViewToggleBtn, UsageMon:Hwnd, UsageMonViewToggleBtn
    usageMonitorCtrlColors[usageMonitorHwndViewToggleBtn] := 0xD4D4D4
    GuiControlGet, usageMonitorHwndResetToggleBtn, UsageMon:Hwnd, UsageMonResetToggleBtn
    GuiControlGet, usageMonitorHwndLoginHint, UsageMon:Hwnd, UsageMonLoginHint
    GuiControlGet, usageMonitorHwndDragHandle, UsageMon:Hwnd, UsageMonDragHandle
    usageMonitorCtrlColors[usageMonitorHwndDragHandle] := 0x888888
    GuiControlGet, usageMonitorHwndCloseBtn, UsageMon:Hwnd, UsageMonCloseBtn
    usageMonitorCtrlColors[usageMonitorHwndCloseBtn] := 0x5555FF
    ; pressNudge=false: a 1px press-shift would call GuiControl Move on this static every
    ; hover/press/release, and that runtime re-layout drops its SS_CENTERIMAGE vertical
    ; centering — leaving the +/- looking off-center after the first interaction. Color-only
    ; hover/press feedback still works via WM_CTLCOLORSTATIC.
    UsageMonitorRegisterButton(usageMonitorHwndViewToggleBtn, "UsageMonViewToggleBtn", "view", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndClaudeAccountSignal, "UsageMonClaudeAccountSignal", "claude-account-mini", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndMiniHideCodex, "UsageMonMiniHideCodex", "mini-hide-codex", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndMiniHideClaude, "UsageMonMiniHideClaude", "mini-hide-claude", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    UsageMonitorRegisterButton(usageMonitorHwndMiniHideGrok, "UsageMonMiniHideGrok", "mini-hide-grok", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)
    if (usageMonitorAddonActive)
        UsageMonitorRegisterButton(usageMonitorHwndMiniHideAddon, "UsageMonMiniHideAddon", "mini-hide-addon", 0xD4D4D4, 0xFFFFFF, 0xFFFFFF, 0x1E1E1E, 0x303030, 0x3F3F3F, false)

    usageMonitorHwndCodexDailyBar := 0
    usageMonitorHwndCodexWeeklyBar := 0
    usageMonitorHwndClaudeDailyBar := 0
    usageMonitorHwndClaudeWeeklyBar := 0
    usageMonitorHwndClaudeFableBar := 0
    usageMonitorHwndGrokMonthlyBar := 0   ; mini view has no progress bars
    usageMonitorHwndAddonLine1Bar := 0
    usageMonitorHwndAddonLine2Bar := 0

    ; Vertical dividers are empty statics filled by their background brush, registered with the
    ; DEFAULT divider COLORREF so UsageMonitorApplyTheme's remap carries them to the live theme.
    usageMonitorCtrlBgColors[usageMonitorHwndMiniDivider] := 0x808080
    usageMonitorCtrlBgColors[usageMonitorHwndMiniDivider2] := 0x808080
    if (usageMonitorHwndMiniDivider3)
        usageMonitorCtrlBgColors[usageMonitorHwndMiniDivider3] := 0x808080

    usageMonitorGuiReady := true
    usageMonitorBuiltUiScale := usageMonitorUiScale . "|" . usageMonitorUiFontScale
    usageMonitorBuiltViewMode := usageMonitorViewMode
    usageMonitorBuiltTheme := usageMonitorTheme
    usageMonitorBuiltClaudeFable := usageMonitorClaudeFableActive
    UsageMonitorUpdateViewToggleText()
    UsageMonitorUpdateResetToggleText()
    UsageMonitorApplyTheme()
}

UsageMonitorPrepareProgressBar(hwnd)
{
    if (!hwnd)
        return
    DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "WStr", "", "WStr", "")
    SendMessage, 0x2001, 0, 0x2D2D2D,, ahk_id %hwnd%
}

UsageMonitorMakeSpriteClickThrough()
{
    global usageMonitorHwndSprite

    if (!usageMonitorHwndSprite)
        return

    UsageMonitorMakeWindowClickThrough(usageMonitorHwndSprite)
    enumCallback := RegisterCallback("UsageMonitorSpriteChildClickThrough", "Fast")
    DllCall("EnumChildWindows", "Ptr", usageMonitorHwndSprite, "Ptr", enumCallback, "Ptr", 0)
}

UsageMonitorScheduleSpriteBuild()
{
    global usageMonitorVisible, usageMonitorViewMode, usageMonitorHwndSprite, usageMonitorSpritePath

    SetTimer, UsageMonitorDeferredSpriteBuild, Off
    if (usageMonitorVisible && usageMonitorViewMode = "full" && !usageMonitorHwndSprite && usageMonitorSpritePath != "")
        SetTimer, UsageMonitorDeferredSpriteBuild, -25
}

UsageMonitorPositionSprite()
{
    global usageMonitorHwnd, usageMonitorHwndSprite, usageMonitorHwndSpritePlaceholder

    if (!usageMonitorHwnd || (!usageMonitorHwndSpritePlaceholder && !usageMonitorHwndSprite))
        return false

    WinGetPos, , , usMonFullW, usMonFullH, ahk_id %usageMonitorHwnd%
    if (usMonFullW = "" || usMonFullH = "")
        return false

    spriteX := usMonFullW - UsScale(120) - UsScale(6)
    spriteY := usMonFullH - UsScale(95) - UsScale(6)
    if (spriteX < UsScale(150))
        spriteX := UsScale(150)
    if (spriteY < UsScale(40))
        spriteY := UsScale(40)

    if (usageMonitorHwndSpritePlaceholder)
        GuiControl, UsageMon:Move, UsageMonSpritePlaceholder, % "x" . spriteX . " y" . spriteY
    if (usageMonitorHwndSprite)
        GuiControl, UsageMon:Move, UsageMonSpriteCtrl, % "x" . spriteX . " y" . spriteY
    return true
}

UsageMonitorBuildSprite()
{
    global usageMonitorVisible, usageMonitorViewMode, usageMonitorHwnd, usageMonitorHwndSprite
    global usageMonitorHwndSpritePlaceholder, usageMonitorSpritePath, UsageMonSpriteCtrl

    if (!usageMonitorVisible || usageMonitorViewMode != "full" || !usageMonitorHwnd)
        return false
    if (usageMonitorHwndSprite || usageMonitorSpritePath = "" || !FileExist(usageMonitorSpritePath))
        return false

    if (!UsageMonitorPositionSprite())
        return false
    GuiControlGet, spritePos, UsageMon:Pos, UsageMonSpritePlaceholder
    spriteX := spritePosX
    spriteY := spritePosY

    try {
        Gui, UsageMon:Add, ActiveX, % "x" . spriteX . " y" . spriteY . " w" . UsScale(120) . " h" . UsScale(95) . " vUsageMonSpriteCtrl", Shell.Explorer
        GuiControlGet, usageMonitorHwndSprite, UsageMon:Hwnd, UsageMonSpriteCtrl
        try UsageMonSpriteCtrl.Silent := true
        UsageMonSpriteCtrl.Navigate("about:blank")
        while (UsageMonSpriteCtrl.readyState != 4)
            Sleep, 10
        ; Shell.Explorer can inherit a stale Internet Explorer optical zoom. At 125% the
        ; nominally 100%-sized image is enlarged beyond the host and loses its top/right
        ; edges. Force a deterministic 100% before writing the animation document.
        try UsageMonSpriteCtrl.ExecWB(63, 2, 100, 0) ; OLECMDID_OPTICAL_ZOOM
        spriteGifUrl := "file:///" . StrReplace(usageMonitorSpritePath, "\", "/")
        doc := UsageMonSpriteCtrl.document
        doc.open()
        ; img sized 100% (not fixed px): the WebBrowser control zooms CSS pixels by the SYSTEM
        ; DPI while the ActiveX box is physical (-DPIScale), so fixed px would crop on high-DPI
        ; systems. Percent sizing fills the UsScale'd box regardless of the control's zoom.
        doc.write("<!doctype html><html style='margin:0;padding:0;overflow:hidden;background:#1E1E1E'><head><meta http-equiv='X-UA-Compatible' content='IE=edge'><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#1E1E1E;}*{background-color:#1E1E1E;}img{display:block;width:100%;height:100%;border:0;pointer-events:none;}</style></head><body scroll='no' style='pointer-events:none' oncontextmenu='return false' onselectstart='return false'><img src='" . spriteGifUrl . "'></body></html>")
        doc.close()
        if (usageMonitorHwndSpritePlaceholder)
            GuiControl, UsageMon:Hide, UsageMonSpritePlaceholder
        UsageMonitorMakeSpriteClickThrough()
        return true
    }
    return false
}

UsageMonitorSpriteChildClickThrough(hwnd, lParam)
{
    UsageMonitorMakeWindowClickThrough(hwnd)
    return true
}

UsageMonitorMakeWindowClickThrough(hwnd)
{
    if (!hwnd)
        return
    DllCall("EnableWindow", "Ptr", hwnd, "Int", false)
    WinSet, ExStyle, +0x20, ahk_id %hwnd%
}

UsageMonitorUpdateViewToggleText()
{
    global usageMonitorViewMode, usageMonitorHwndViewToggleBtn
    if (!usageMonitorHwndViewToggleBtn)
        return
    toggleText := (usageMonitorViewMode = "mini") ? "+" : "-"
    GuiControl, UsageMon:, UsageMonViewToggleBtn, %toggleText%
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndViewToggleBtn)
}

UsageMonitorUpdateResetToggleText()
{
    global usageMonitorShowResetDates, usageMonitorHwndResetToggleBtn, usageMonitorCtrlColors
    if (!usageMonitorHwndResetToggleBtn)
        return
    usageMonitorCtrlColors[usageMonitorHwndResetToggleBtn] := UsageMonitorThemeRef("text")
    UsageMonitorSetButtonDefaultVisual(usageMonitorHwndResetToggleBtn, UsageMonitorThemeRef("text"))
    GuiControl, UsageMon:, UsageMonResetToggleBtn, Resets
    DllCall("InvalidateRect", "Ptr", usageMonitorHwndResetToggleBtn, "Ptr", 0, "Int", true)
}

UsageMonitorUpdateClaudeAccountToggleGlyph()
{
    global usageMonitorShowClaudeAccountFull, usageMonitorHwndClaudeAccountToggle
    if (!usageMonitorHwndClaudeAccountToggle)
        return
    glyph := usageMonitorShowClaudeAccountFull ? Chr(0x1F441) : Chr(0x1F648)  ; eye / see-no-evil
    GuiControl, UsageMon:, UsageMonClaudeAccountToggle, %glyph%
    DllCall("InvalidateRect", "Ptr", usageMonitorHwndClaudeAccountToggle, "Ptr", 0, "Int", true)
}

; WM_CTLCOLORSTATIC. Critical here is load-bearing, not a micro-optimisation.
; This message is SENT, never posted, so AHK cannot buffer it: any WM_CTLCOLORSTATIC that
; arrives while a previous call to this monitor is still on the stack is DROPPED, and the
; control then paints via AHK's own Gui handling with its build-time Gui Font color.
; Without Critical, any of the recurring 200 ms timers (snapshot poll / anchor track /
; focus border) or the WM_MOUSEMOVE monitor can interrupt this callback once it is past its
; first 15 ms — and every repaint that interrupting thread provokes is dropped for as long
; as this call sits unfinished. That is why misses arrived a whole column at a time rather
; than one stray control. Critical makes this callback atomic so it always returns before
; anything else can force a paint.
UsageMonCTLColorStatic(wParam, lParam, msg, hwnd)
{
    global usageMonitorCtrlColors, usageMonitorCtrlBgColors, usageMonitorBgBrush, usageMonitorHwnd

    Critical

    if (hwnd != usageMonitorHwnd)
        return

    bgColorRef := UsageMonitorThemeRef("bg")
    if (usageMonitorCtrlBgColors.HasKey(lParam))
        bgColorRef := usageMonitorCtrlBgColors[lParam]
    DllCall("SetBkColor", "Ptr", wParam, "UInt", bgColorRef)
    if (usageMonitorCtrlColors.HasKey(lParam))
        DllCall("SetTextColor", "Ptr", wParam, "UInt", usageMonitorCtrlColors[lParam])

    return UsageMonitorGetBgBrush(bgColorRef)
}

; The cached brushes are GDI objects this script owns (CreateSolidBrush below), so the cache
; cannot just be re-assigned -- that leaked one brush per distinct background color on every
; build and rebuild (view toggle, theme toggle, Fable row change, DPI change). Safe to delete
; here: this only ever runs from UsageMonitorApplyTheme at the end of a build, on the script
; thread, when the previous generation's controls are already destroyed and no paint is in
; flight. usageMonitorBgBrush can alias one of these, so it is cleared with them.
UsageMonitorReleaseBgBrushes()
{
    global usageMonitorCtrlBgBrushes, usageMonitorBgBrush

    if (IsObject(usageMonitorCtrlBgBrushes))
    {
        for _, brush in usageMonitorCtrlBgBrushes
            if (brush)
                DllCall("DeleteObject", "Ptr", brush)
    }
    usageMonitorCtrlBgBrushes := {}
    usageMonitorBgBrush := 0
}

UsageMonitorGetBgBrush(colorRef)
{
    global usageMonitorCtrlBgBrushes, usageMonitorBgBrush

    brushKey := "" . colorRef
    if (IsObject(usageMonitorCtrlBgBrushes) && usageMonitorCtrlBgBrushes.HasKey(brushKey))
        return usageMonitorCtrlBgBrushes[brushKey]

    brush := DllCall("CreateSolidBrush", "UInt", colorRef, "Ptr")
    if (!IsObject(usageMonitorCtrlBgBrushes))
        usageMonitorCtrlBgBrushes := {}
    usageMonitorCtrlBgBrushes[brushKey] := brush
    if (!usageMonitorBgBrush && colorRef = 0x1E1E1E)
        usageMonitorBgBrush := brush
    return brush
}

UsageMonitorRegisterButton(hwnd, ctrlName, groupName := "", defaultTextColor := 0xD4D4D4
    , hoverTextColor := 0xFFFFFF, pressedTextColor := 0xFFFFFF
    , defaultBgColor := 0x1E1E1E, hoverBgColor := 0x303030, pressedBgColor := 0x3F3F3F
    , pressNudge := true)
{
    global usageMonitorButtons, usageMonitorButtonGroups, usageMonitorCtrlColors, usageMonitorCtrlBgColors
    if (!hwnd || ctrlName = "")
        return false

    if (groupName = "")
        groupName := "" . hwnd

    if (!UsageMonitorGetControlClientRect(hwnd, x, y, w, h))
        x := 0, y := 0, w := 0, h := 0

    btn := { ctrl: ctrlName
        , group: groupName
        , x: x, y: y, w: w, h: h
        , defaultText: defaultTextColor
        , hoverText: hoverTextColor
        , pressedText: pressedTextColor
        , defaultBg: defaultBgColor
        , hoverBg: hoverBgColor
        , pressedBg: pressedBgColor
        , nudge: pressNudge ? true : false }

    usageMonitorButtons[hwnd] := btn
    if (!usageMonitorButtonGroups.HasKey(groupName))
        usageMonitorButtonGroups[groupName] := []
    usageMonitorButtonGroups[groupName].Push(hwnd)

    usageMonitorCtrlColors[hwnd] := defaultTextColor
    usageMonitorCtrlBgColors[hwnd] := defaultBgColor
    return true
}

UsageMonitorGetControlClientRect(hwnd, ByRef x, ByRef y, ByRef w, ByRef h)
{
    global usageMonitorHwnd
    x := 0, y := 0, w := 0, h := 0
    if (!hwnd || !usageMonitorHwnd)
        return false

    VarSetCapacity(rect, 16, 0)
    if (!DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", &rect))
        return false

    left := NumGet(rect, 0, "Int")
    top := NumGet(rect, 4, "Int")
    right := NumGet(rect, 8, "Int")
    bottom := NumGet(rect, 12, "Int")

    VarSetCapacity(pt, 8, 0)
    NumPut(left, pt, 0, "Int")
    NumPut(top, pt, 4, "Int")
    DllCall("ScreenToClient", "Ptr", usageMonitorHwnd, "Ptr", &pt)

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
    w := right - left
    h := bottom - top
    return (w > 0 && h > 0)
}

UsageMonitorRefreshButtonBaseRect(hwnd)
{
    global usageMonitorButtons
    if (!hwnd || !usageMonitorButtons.HasKey(hwnd))
        return false
    if (!UsageMonitorGetControlClientRect(hwnd, x, y, w, h))
        return false

    usageMonitorButtons[hwnd].x := x
    usageMonitorButtons[hwnd].y := y
    usageMonitorButtons[hwnd].w := w
    usageMonitorButtons[hwnd].h := h
    return true
}

UsageMonitorSetButtonDefaultVisual(hwnd, textColor, bgColor := "")
{
    global usageMonitorButtons, usageMonitorCtrlColors, usageMonitorCtrlBgColors
    global usageMonitorButtonHoverGroup, usageMonitorButtonPressedGroup
    if (!hwnd || !usageMonitorButtons.HasKey(hwnd))
        return false
    if (bgColor = "")
        bgColor := UsageMonitorThemeRef("bg")

    usageMonitorButtons[hwnd].defaultText := textColor
    usageMonitorButtons[hwnd].defaultBg := bgColor
    groupName := usageMonitorButtons[hwnd].group
    if (groupName != usageMonitorButtonHoverGroup && groupName != usageMonitorButtonPressedGroup)
    {
        usageMonitorCtrlColors[hwnd] := textColor
        usageMonitorCtrlBgColors[hwnd] := bgColor
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", true)
    }
    return true
}

UsageMonitorApplyButtonGroupState(groupName, state)
{
    global usageMonitorButtonGroups
    if (groupName = "" || !usageMonitorButtonGroups.HasKey(groupName))
        return false

    for _, hwnd in usageMonitorButtonGroups[groupName]
        UsageMonitorApplyButtonState(hwnd, state)
    return true
}

UsageMonitorApplyButtonState(hwnd, state)
{
    global usageMonitorButtons, usageMonitorCtrlColors, usageMonitorCtrlBgColors
    if (!hwnd || !usageMonitorButtons.HasKey(hwnd))
        return false

    btn := usageMonitorButtons[hwnd]
    offset := 0
    if (state = "pressed")
    {
        textColor := btn.pressedText
        bgColor := btn.pressedBg
        offset := btn.nudge ? UsScale(1) : 0
    }
    else if (state = "hover")
    {
        textColor := btn.hoverText
        bgColor := btn.hoverBg
    }
    else
    {
        textColor := btn.defaultText
        bgColor := btn.defaultBg
    }

    usageMonitorCtrlColors[hwnd] := textColor
    usageMonitorCtrlBgColors[hwnd] := bgColor
    if (btn.nudge)
        GuiControl, UsageMon:Move, % btn.ctrl, % "x" . (btn.x + offset) . " y" . (btn.y + offset) . " w" . btn.w . " h" . btn.h
    DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", true)
    return true
}

UsageMonitorButtonGroupAt(mx, my)
{
    global usageMonitorButtons
    for hwnd, btn in usageMonitorButtons
    {
        ; The account label is a hover target while it switches accounts or shows the CLI tag.
        if (btn.group = "claude-account" && !UsageMonitorClaudeAccountSwitchEnabled() && !UsageMonitorClaudeSourceIsCli())
            continue
        if (UsageMonitorPointInControl(hwnd, mx, my, true, UsScale(3)))
            return btn.group
    }
    return ""
}

UsageMonitorUpdateHoverTooltip(groupName, mx, my)
{
    global usageMonitorHwnd
    global usageMonitorTooltipGroup, usageMonitorTooltipStartTick
    global usageMonitorTooltipMouseX, usageMonitorTooltipMouseY, usageMonitorTooltipShown
    global usageMonitorTooltipDelayMs, usageMonitorTooltipId

    if (groupName = "" || UsageMonitorMouseButtonPressed())
    {
        UsageMonitorHideHoverTooltip()
        return
    }

    if (groupName != usageMonitorTooltipGroup || mx != usageMonitorTooltipMouseX || my != usageMonitorTooltipMouseY)
    {
        UsageMonitorHideHoverTooltip(false)
        usageMonitorTooltipGroup := groupName
        usageMonitorTooltipMouseX := mx
        usageMonitorTooltipMouseY := my
        usageMonitorTooltipStartTick := A_TickCount
        return
    }

    if (usageMonitorTooltipShown)
        return

    if ((A_TickCount - usageMonitorTooltipStartTick) < usageMonitorTooltipDelayMs)
        return

    tipText := UsageMonitorTooltipText(groupName)
    if (tipText = "")
        return

    tipX := mx + UsScale(12)
    tipY := my + UsScale(18)
    if (usageMonitorHwnd)
    {
        wx := 0, wy := 0, ww := 0, wh := 0
        WinGetPos, wx, wy, ww, wh, ahk_id %usageMonitorHwnd%
        if (ww > 0 && wh > 0)
        {
            SysGet, virtualLeft, 76
            SysGet, virtualTop, 77
            SysGet, virtualWidth, 78
            SysGet, virtualHeight, 79
            virtualRight := virtualLeft + virtualWidth
            virtualBottom := virtualTop + virtualHeight
            estimatedW := UsScale(320)
            estimatedH := UsScale(32)

            tipX := wx + ww + UsScale(8)
            if (tipX + estimatedW > virtualRight)
                tipX := wx - estimatedW - UsScale(8)
            if (tipX < virtualLeft)
                tipX := virtualLeft + UsScale(4)

            if (tipY + estimatedH > virtualBottom)
                tipY := virtualBottom - estimatedH
            if (tipY < virtualTop)
                tipY := virtualTop + UsScale(4)
        }
    }
    CoordMode, ToolTip, Screen
    ToolTip, %tipText%, %tipX%, %tipY%, %usageMonitorTooltipId%
    usageMonitorTooltipShown := true
}

UsageMonitorHideHoverTooltip(resetState := true)
{
    global usageMonitorTooltipGroup, usageMonitorTooltipStartTick
    global usageMonitorTooltipMouseX, usageMonitorTooltipMouseY, usageMonitorTooltipShown
    global usageMonitorTooltipId

    ToolTip,,,, %usageMonitorTooltipId%
    usageMonitorTooltipShown := false
    if (resetState)
    {
        usageMonitorTooltipGroup := ""
        usageMonitorTooltipStartTick := 0
        usageMonitorTooltipMouseX := ""
        usageMonitorTooltipMouseY := ""
    }
}

UsageMonitorMouseButtonPressed()
{
    return GetKeyState("LButton", "P")
        || GetKeyState("RButton", "P")
        || GetKeyState("MButton", "P")
}

; Hover text naming the login a provider's numbers came from (the snapshot's <provider>_source).
; Lines stay short: UsageMonitorUpdateHoverTooltip places the tip for a width of about 320px.
UsageMonitorSourceTooltip(provider)
{
    global usageMonitorLastSnapshot, usageMonitorAddonHint

    source := IsObject(usageMonitorLastSnapshot) ? UsageMonitorValue(usageMonitorLastSnapshot, provider . "_source", "") : ""
    if (UsageMonitorProviderShownOff(provider, IsObject(usageMonitorLastSnapshot) ? UsageMonitorValue(usageMonitorLastSnapshot, provider . "_status", "") : ""))
        return UsageMonitorProviderDisplayName(provider) . " is off in Settings:`nno login is read, no request made."
    if (provider = "codex")
    {
        if (source = "cli")
            return "Source: your Codex CLI login."
        if (source = "firefox")
            return "Source: your Firefox session`n(no working Codex CLI login)."
        return "No working Codex login: run codex,`nor sign in to chatgpt.com in Firefox."
    }
    if (provider = "claude")
    {
        if (source = "cli")
            return "Source: your Claude Code login."
        if (source = "firefox")
            return "Source: the monitored Firefox profile`n(no working Claude Code login)."
        return "No working Claude login: run claude,`nor sign in to claude.ai in Firefox."
    }
    if (provider = "grok")
    {
        if (source = "cli")
            return "Source: your Grok CLI login."
        if (source = "firefox")
            return "Source: your Firefox session`n(no working Grok CLI login)."
        return "No working Grok login: run grok login,`nor sign in to grok.com in Firefox."
    }
    ; The add-on: its source tag comes from the module (a-z only, checked by the scraper).
    if (RegExMatch(source, "^[a-z]{1,8}$"))
        return "Source: the " . UsageMonitorAddonDisplayLabel() . " add-on (" . source . ")."
    return "No working " . UsageMonitorAddonDisplayLabel() . " login." . (usageMonitorAddonHint != "" ? "`n" . usageMonitorAddonHint : "")
}

UsageMonitorTooltipText(groupName)
{
    global usageMonitorViewMode, usageMonitorShowClaudeAccountFull
    global usageMonitorShowClaudeAccountMini
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode, usageMonitorMiniAddonMode
    global usageMonitorAddonLink

    if (groupName = "view")
    {
        if (usageMonitorViewMode = "mini")
            return "Restore the full usage monitor."
        return "Switch to the compact mini monitor."
    }
    if (groupName = "close")
        return "Close the usage monitor."
    if (groupName = "drag")
    {
        if (usageMonitorViewMode = "mini")
            return "Drag the mini monitor to move it. Placement is remembered per app."
        return "Drag this handle to move the usage monitor. Placement is remembered per app."
    }
    if (groupName = "provider-link-codex")
        return UsageMonitorSourceTooltip("codex") . "`nClick to open Codex usage in Firefox."
    if (groupName = "provider-link-claude")
        return UsageMonitorSourceTooltip("claude") . "`nClick to open Claude usage in Firefox."
    if (groupName = "provider-link-grok")
        return UsageMonitorSourceTooltip("grok") . "`nClick to open Grok usage in Firefox."
    if (groupName = "provider-link-addon")
        return UsageMonitorSourceTooltip("addon") . (UsageMonitorAddonLinkIsSafe(usageMonitorAddonLink) ? "`nClick to open " . UsageMonitorAddonDisplayLabel() . " in Firefox." : "")
    if (groupName = "provider-source-codex")
        return UsageMonitorSourceTooltip("codex")
    if (groupName = "provider-source-grok")
        return UsageMonitorSourceTooltip("grok")
    if (groupName = "provider-source-addon")
        return UsageMonitorSourceTooltip("addon")
    if (groupName = "claude-account" && UsageMonitorClaudeSourceIsCli())
        return UsageMonitorSourceTooltip("claude")
    if (groupName = "claude-account" && UsageMonitorClaudeAccountSwitchEnabled())
        return "Switch Monitored Account?"
    if (groupName = "claude-account-toggle")
        return usageMonitorShowClaudeAccountFull ? "Hide monitored account" : "Show monitored account"
    if (groupName = "claude-account-mini")
        return usageMonitorShowClaudeAccountMini ? "Hide monitored account" : "Show monitored account"
    if (groupName = "mini-hide-codex")
        return "Hide Codex from mini view."
    if (groupName = "mini-hide-claude")
        return "Hide Claude from mini view."
    if (groupName = "mini-hide-grok")
        return "Hide Grok from mini view."
    if (groupName = "mini-hide-addon")
        return "Hide " . UsageMonitorAddonDisplayLabel() . " from mini view."
    if (groupName = "mini-toggle-codex")
        return "Codex mini mode: " . usageMonitorMiniCodexMode . ". Click to cycle Auto, Free, On, Off."
    if (groupName = "mini-toggle-claude")
        return "Claude mini mode: " . usageMonitorMiniClaudeMode . ". Click to cycle Auto, Free, On, Off."
    if (groupName = "mini-toggle-grok")
        return "Grok mini mode: " . usageMonitorMiniGrokMode . ". Click to cycle Auto, Free, On, Off."
    if (groupName = "mini-toggle-addon")
        return UsageMonitorAddonDisplayLabel() . " mini mode: " . usageMonitorMiniAddonMode . ". Click to cycle Auto, Free, On, Off."
    return ""
}

UsageMonitorUpdateMiniHideHover(mx, my, overWindow)
{
    global usageMonitorViewMode
    global usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndGrokMonthly, usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global UsageMonMiniHideCodex, UsageMonMiniHideClaude, UsageMonMiniHideGrok, UsageMonMiniHideAddon
    global usageMonitorAddonActive

    if (usageMonitorViewMode != "mini" || !overWindow)
        target := ""
    else if (UsageMonitorPointInControl(usageMonitorHwndCodexDaily, mx, my)
        || UsageMonitorPointInControl(usageMonitorHwndCodexWeekly, mx, my))
        target := "codex"
    else if (UsageMonitorPointInControl(usageMonitorHwndClaudeDaily, mx, my)
        || UsageMonitorPointInControl(usageMonitorHwndClaudeWeekly, mx, my))
        target := "claude"
    else if (UsageMonitorPointInControl(usageMonitorHwndGrokMonthly, mx, my))
        target := "grok"
    else if (UsageMonitorPointInControl(usageMonitorHwndAddonLine1, mx, my)
        || UsageMonitorPointInControl(usageMonitorHwndAddonLine2, mx, my))
        target := "addon"
    else
    {
        GuiControlGet, codexHeaderHwnd, UsageMon:Hwnd, UsageMonCodexHeader
        GuiControlGet, claudeHeaderHwnd, UsageMon:Hwnd, UsageMonClaudeHeader
        GuiControlGet, grokHeaderHwnd, UsageMon:Hwnd, UsageMonGrokHeader
        addonHeaderHwnd := 0
        if (usageMonitorAddonActive)
            GuiControlGet, addonHeaderHwnd, UsageMon:Hwnd, UsageMonAddonHeader
        target := UsageMonitorPointInControl(codexHeaderHwnd, mx, my) ? "codex"
            : UsageMonitorPointInControl(claudeHeaderHwnd, mx, my) ? "claude"
            : UsageMonitorPointInControl(grokHeaderHwnd, mx, my) ? "grok"
            : UsageMonitorPointInControl(addonHeaderHwnd, mx, my) ? "addon" : ""
    }

    GuiControl, % "UsageMon:" . (target = "codex" ? "Show" : "Hide"), UsageMonMiniHideCodex
    GuiControl, % "UsageMon:" . (target = "claude" ? "Show" : "Hide"), UsageMonMiniHideClaude
    GuiControl, % "UsageMon:" . (target = "grok" ? "Show" : "Hide"), UsageMonMiniHideGrok
    if (usageMonitorAddonActive)
        GuiControl, % "UsageMon:" . (target = "addon" ? "Show" : "Hide"), UsageMonMiniHideAddon
}

UsageMonitorUpdateButtonVisuals(mx := "", my := "", overWindow := "")
{
    global usageMonitorHwnd, usageMonitorButtonHoverGroup, usageMonitorButtonPressedGroup
    if (!usageMonitorHwnd)
        return

    if (mx = "" || my = "")
    {
        CoordMode, Mouse, Screen
        MouseGetPos, mx, my
    }

    if (overWindow = "")
    {
        WinGetPos, wx, wy, ww, wh, ahk_id %usageMonitorHwnd%
        overWindow := (mx >= wx && mx < wx + ww && my >= wy && my < wy + wh)
    }

    if (usageMonitorButtonPressedGroup != "")
    {
        UsageMonitorHideHoverTooltip()
        return
    }

    UsageMonitorUpdateMiniHideHover(mx, my, overWindow)

    nextHoverGroup := overWindow ? UsageMonitorButtonGroupAt(mx, my) : ""
    UsageMonitorUpdateHoverTooltip(nextHoverGroup, mx, my)
    if (nextHoverGroup = usageMonitorButtonHoverGroup)
        return

    if (usageMonitorButtonHoverGroup != "")
        UsageMonitorApplyButtonGroupState(usageMonitorButtonHoverGroup, "default")

    usageMonitorButtonHoverGroup := nextHoverGroup
    if (usageMonitorButtonHoverGroup != "")
        UsageMonitorApplyButtonGroupState(usageMonitorButtonHoverGroup, "hover")
}

UsageMonitorPressButtonAtCursor()
{
    global usageMonitorButtonHoverGroup, usageMonitorButtonPressedGroup
    UsageMonitorHideHoverTooltip()
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my
    groupName := UsageMonitorButtonGroupAt(mx, my)
    if (groupName = "")
        return ""

    if (usageMonitorButtonHoverGroup != "" && usageMonitorButtonHoverGroup != groupName)
        UsageMonitorApplyButtonGroupState(usageMonitorButtonHoverGroup, "default")

    usageMonitorButtonHoverGroup := groupName
    usageMonitorButtonPressedGroup := groupName
    UsageMonitorApplyButtonGroupState(groupName, "pressed")
    SetTimer, UsageMonitorButtonPressFallback, -350
    return groupName
}

UsageMonitorReleasePressedButton()
{
    global usageMonitorButtonHoverGroup, usageMonitorButtonPressedGroup
    if (usageMonitorButtonPressedGroup = "")
        return

    releasedGroup := usageMonitorButtonPressedGroup
    usageMonitorButtonPressedGroup := ""
    usageMonitorButtonHoverGroup := ""
    UsageMonitorApplyButtonGroupState(releasedGroup, "default")
    UsageMonitorUpdateButtonVisuals()
}

UsageMonitorGetGrabCursor()
{
    static sGrabCursor := 0
    local grabPattern, grabWidth, grabHeight, grabY, grabX, grabRow, grabCh
    local grabBmi, grabHdc, grabBits, grabColorBitmap, grabMaskBitmap, grabMaskBits
    local grabPixelOffset, grabPixelColor, grabIconInfo, grabMaskOffset

    if (sGrabCursor)
        return sGrabCursor

    ; Compact Windows-11-style closed-hand (grab) cursor, ~15x13 px of a 32x32 ARGB canvas.
    ; W=white fill, B=dark outline, A=semi-transparent edge anti-alias, G=finger-crease fade.
    grabPattern := []
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("............ABBA................")
    grabPattern.Push(".........ABBBWWBBBA.............")
    grabPattern.Push(".........BWWBWWBWWBBBA..........")
    grabPattern.Push(".........BWWBWWBWWBWWB..........")
    grabPattern.Push(".........BWWBWWBWWBWWB..........")
    grabPattern.Push("........ABWWGWWGWWGWWBA.........")
    grabPattern.Push("........BWWWWWWWWWWWWWB.........")
    grabPattern.Push("........BWWWWWWWWWWWWWB.........")
    grabPattern.Push("........BWWWWWWWWWWWWWB.........")
    grabPattern.Push("........ABWWWWWWWWWWWBA.........")
    grabPattern.Push(".........ABWWWWWWWWWBA..........")
    grabPattern.Push("..........ABWWWWWWWBA...........")
    grabPattern.Push("...........ABBBBBBBA............")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")
    grabPattern.Push("................................")

    grabWidth := 32
    grabHeight := 32

    VarSetCapacity(grabBmi, 40, 0)
    NumPut(40, grabBmi, 0, "UInt")
    NumPut(grabWidth, grabBmi, 4, "Int")
    NumPut(-grabHeight, grabBmi, 8, "Int")
    NumPut(1, grabBmi, 12, "UShort")
    NumPut(32, grabBmi, 14, "UShort")

    grabBits := 0
    grabHdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    if (!grabHdc)
        return 0

    grabColorBitmap := DllCall("CreateDIBSection"
        , "Ptr", grabHdc
        , "Ptr", &grabBmi
        , "UInt", 0
        , "PtrP", grabBits
        , "Ptr", 0
        , "UInt", 0
        , "Ptr")
    if (!grabColorBitmap)
    {
        DllCall("DeleteDC", "Ptr", grabHdc)
        return 0
    }

    Loop, %grabHeight%
    {
        grabY := A_Index - 1
        grabRow := grabPattern[A_Index]
        Loop, %grabWidth%
        {
            grabX := A_Index - 1
            grabCh := SubStr(grabRow, A_Index, 1)
            if (grabCh = ".")
                continue

            grabPixelColor := 0
            if (grabCh = "W")
                grabPixelColor := 0xFFFFFFFF
            else if (grabCh = "B")
                grabPixelColor := 0xFF202020
            else if (grabCh = "A")
                grabPixelColor := 0x7D000000
            else if (grabCh = "G")
                grabPixelColor := 0xFFC8C8C8

            if (grabPixelColor)
            {
                grabPixelOffset := ((grabY * grabWidth) + grabX) * 4
                NumPut(grabPixelColor, grabBits + grabPixelOffset, 0, "UInt")
            }
        }
    }

    VarSetCapacity(grabMaskBits, (grabWidth // 8) * grabHeight, 0)
    grabMaskBitmap := DllCall("CreateBitmap"
        , "Int", grabWidth
        , "Int", grabHeight
        , "UInt", 1
        , "UInt", 1
        , "Ptr", &grabMaskBits
        , "Ptr")

    if (grabMaskBitmap)
    {
        VarSetCapacity(grabIconInfo, A_PtrSize = 8 ? 32 : 20, 0)
        NumPut(0, grabIconInfo, 0, "UInt")
        NumPut(15, grabIconInfo, 4, "UInt")
        NumPut(15, grabIconInfo, 8, "UInt")
        grabMaskOffset := (A_PtrSize = 8) ? 16 : 12
        NumPut(grabMaskBitmap, grabIconInfo, grabMaskOffset, "Ptr")
        NumPut(grabColorBitmap, grabIconInfo, grabMaskOffset + A_PtrSize, "Ptr")
        sGrabCursor := DllCall("CreateIconIndirect", "Ptr", &grabIconInfo, "Ptr")
    }

    DllCall("DeleteObject", "Ptr", grabColorBitmap)
    if (grabMaskBitmap)
        DllCall("DeleteObject", "Ptr", grabMaskBitmap)
    DllCall("DeleteDC", "Ptr", grabHdc)
    return sGrabCursor
}

UsageMonitorSetDragCursor(cursorState := "hand")
{
    static handCursor := 0
    local dragCursor

    if (!handCursor)
        handCursor := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")  ; IDC_HAND

    dragCursor := (cursorState = "grab") ? UsageMonitorGetGrabCursor() : handCursor
    if (!dragCursor)
        dragCursor := handCursor

    if (dragCursor)
    {
        DllCall("SetCursor", "Ptr", dragCursor)
        return true
    }
    return false
}

UsageMonitorCursorOverWindow()
{
    local mx, my
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my
    return UsageMonitorPointInWindow(mx, my)
}

; Mini view: the collapsed account dot (·) is a hover-only peek — visible only while the
; cursor is over the HUD, hidden otherwise. The full account code (e.g. j42@) is unaffected
; and stays always-visible. No-op unless mini view is currently showing the dot form.
UsageMonitorUpdateMiniDotHover(overWindow)
{
    global usageMonitorViewMode, usageMonitorShowClaudeAccountMini
    global usageMonitorMiniSignalActive, usageMonitorMiniDotShown

    if (usageMonitorViewMode != "mini")
        return
    if (!usageMonitorMiniSignalActive || usageMonitorShowClaudeAccountMini)
        return  ; not in dot mode (no signal, or showing the full account code)

    desired := overWindow ? true : false
    if (desired = usageMonitorMiniDotShown)
        return
    usageMonitorMiniDotShown := desired
    GuiControl, % "UsageMon:" . (desired ? "Show" : "Hide"), UsageMonClaudeAccountSignal
}

UsageMonitorPointInWindow(screenX, screenY)
{
    global usageMonitorHwnd

    if (!usageMonitorHwnd)
        return false

    WinGetPos, wx, wy, ww, wh, ahk_id %usageMonitorHwnd%
    if (ww = "" || wh = "" || ww <= 0 || wh <= 0)
        return false

    return (screenX >= wx && screenX < wx + ww && screenY >= wy && screenY < wy + wh)
}

; True for the Settings window and its controls. The popup's OnMessage handlers are script-wide,
; so they must leave that window alone: in mini view a click anywhere would otherwise be turned
; into a drag of the popup.
UsageMonitorIsSettingsWindow(hwnd)
{
    global usageMonitorSettingsHwnd
    return (usageMonitorSettingsHwnd && hwnd
        && DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") = usageMonitorSettingsHwnd)   ; GA_ROOT
}

; Intercept left-click on popup: if click lands on drag handle, hand drag to Windows
UsageMonWM_LBUTTONDOWN(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwnd, usageMonitorHwndDragHandle, usageMonitorViewMode
    global usageMonitorHwndViewToggleBtn
    if (UsageMonitorIsSettingsWindow(hwnd))
        return
    pressedGroup := UsageMonitorPressButtonAtCursor()
    if (usageMonitorViewMode = "mini")
    {
        CoordMode, Mouse, Screen
        MouseGetPos, mx, my
        if (pressedGroup != "" || UsageMonitorPointInControl(usageMonitorHwndViewToggleBtn, mx, my))
            return
        UsageMonitorSetDragCursor("grab")
        PostMessage, 0x00A1, 2, 0,, ahk_id %usageMonitorHwnd%  ; WM_NCLBUTTONDOWN HTCAPTION=2
        return 0
    }

    ; Click on the drag handle child fires with hwnd = drag handle HWND (not parent)
    if (hwnd = usageMonitorHwndDragHandle)
    {
        UsageMonitorSetDragCursor("grab")
        PostMessage, 0x00A1, 2, 0,, ahk_id %usageMonitorHwnd%  ; WM_NCLBUTTONDOWN HTCAPTION=2
        return 0
    }
    ; Click elsewhere on the parent window — check if cursor is over drag handle
    if (hwnd != usageMonitorHwnd)
        return
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my
    if (UsageMonitorPointInControl(usageMonitorHwndDragHandle, mx, my))
    {
        UsageMonitorSetDragCursor("grab")
        PostMessage, 0x00A1, 2, 0,, ahk_id %usageMonitorHwnd%
        return 0
    }
}

; Drag started — pause anchor tracking so the 150ms timer doesn't fight Windows' drag loop
UsageMonWM_LBUTTONUP(wParam, lParam, msg, hwnd)
{
    UsageMonitorReleasePressedButton()
}

UsageMonWM_MOUSEMOVE(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwnd, usageMonitorIdleTier

    ; Over the Settings window the popup's hover logic has nothing to do (it hit-tests by screen
    ; position, so it would light a popup button lying under the Settings window).
    if (UsageMonitorIsSettingsWindow(hwnd))
        return

    ; Asleep in the background tier the popup still takes the mouse, so the first move over it
    ; resumes tracking and settles click-through at once, before a click can land.
    if (usageMonitorIdleTier = "background" && usageMonitorHwnd
        && DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") = usageMonitorHwnd)   ; GA_ROOT
    {
        UsageMonitorSetIdleTier("hover")
        UsageMonitorUpdatePassthrough()
        return
    }
    UsageMonitorUpdateButtonVisuals()
}

; Focus landing on the popup itself (a click, Alt+Y, a rebuild re-activating it) wakes a sleeping
; tier here, independent of whether the shell reports the tool window's activation.
UsageMonWM_ACTIVATE(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwnd, usageMonitorIdleTier

    if (hwnd = usageMonitorHwnd && (wParam & 0xFFFF) && usageMonitorIdleTier != "active")
        SetTimer, UsageMonitorIdleWakeTimer, -1
}

UsageMonWM_ENTERSIZEMOVE(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwnd, usageMonitorDragInProgress
    if (hwnd != usageMonitorHwnd)
        return
    usageMonitorDragInProgress := true
}

; After drag ends, record popup offset relative to the current anchor so tracking maintains it.
; Y is stored from the bottom edge, so full/mini rebuilds keep the popup hooked downward.
UsageMonWM_EXITSIZEMOVE(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwnd, usageMonitorDragInProgress
    if (hwnd != usageMonitorHwnd)
        return
    usageMonitorDragInProgress := false
    UsageMonitorReleasePressedButton()
    UsageMonitorCaptureCurrentDragOffset()
}

; Use a hand cursor over draggable surfaces, then a closed hand during drag.
UsageMonWM_SETCURSOR(wParam, lParam, msg, hwnd)
{
    global usageMonitorHwndDragHandle, usageMonitorHwndViewToggleBtn
    global usageMonitorViewMode, usageMonitorDragInProgress
    global usageMonitorHwndClaudeAccountSignal
    global usageMonitorHwndMiniHideCodex, usageMonitorHwndMiniHideClaude, usageMonitorHwndMiniHideGrok
    global usageMonitorHwndCodexHeader, usageMonitorHwndClaudeHeader, usageMonitorHwndGrokHeader
    global usageMonitorHwndGrokMonthly, usageMonitorGrokLinkActive
    global usageMonitorHwndMiniHideAddon, usageMonitorHwndAddonHeader

    if (UsageMonitorIsSettingsWindow(hwnd))
        return
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my

    if (usageMonitorDragInProgress)
    {
        UsageMonitorSetDragCursor("grab")
        return 1
    }

    if (usageMonitorViewMode = "mini")
    {
        if (UsageMonitorPointInWindow(mx, my)
            && !UsageMonitorPointInControl(usageMonitorHwndViewToggleBtn, mx, my, true, UsScale(4))
            && !UsageMonitorPointInControl(usageMonitorHwndClaudeAccountSignal, mx, my, true, UsScale(4))
            && !UsageMonitorPointInControl(usageMonitorHwndMiniHideCodex, mx, my, true, UsScale(2))
            && !UsageMonitorPointInControl(usageMonitorHwndMiniHideClaude, mx, my, true, UsScale(2))
            && !UsageMonitorPointInControl(usageMonitorHwndMiniHideGrok, mx, my, true, UsScale(2))
            && !UsageMonitorPointInControl(usageMonitorHwndMiniHideAddon, mx, my, true, UsScale(2)))
        {
            UsageMonitorSetDragCursor()
            return 1
        }
        return
    }

    if (hwnd = usageMonitorHwndDragHandle || UsageMonitorPointInControl(usageMonitorHwndDragHandle, mx, my, true, UsScale(4)))
    {
        UsageMonitorSetDragCursor()
        return 1
    }
    if (UsageMonitorPointInControl(usageMonitorHwndCodexHeader, mx, my, true, UsScale(4))
        || UsageMonitorPointInControl(usageMonitorHwndClaudeHeader, mx, my, true, UsScale(4))
        || UsageMonitorPointInControl(usageMonitorHwndGrokHeader, mx, my, true, UsScale(4))
        || UsageMonitorPointInControl(usageMonitorHwndAddonHeader, mx, my, true, UsScale(4))
        || (usageMonitorGrokLinkActive && UsageMonitorPointInControl(usageMonitorHwndGrokMonthly, mx, my, true, UsScale(4))))
    {
        UsageMonitorSetDragCursor()
        return 1
    }
}

UsageMonitorGetMetricColorRef(lineText)
{
    local lowerText, pct, match, match1

    ; "Daily: Off" etc.: a provider switched off in Settings reads dim, not as a metric. A bare
    ; "Off" is the add-on switched off before its row labels were ever seen.
    if (RegExMatch(lineText, "i)^([^:]+:\s*)?Off$"))
        return UsageMonitorThemeRef("dim")

    StringLower, lowerText, lineText
    if (InStr(lowerText, "unavailable") || InStr(lowerText, "no subscription") || InStr(lowerText, "n/a") || lineText = "Daily: -" || lineText = "Weekly: -")
        return UsageMonitorThemeRef("text")

    if (!RegExMatch(lineText, "(\d+)%", match))
        return UsageMonitorThemeRef("text")

    pct := match1 + 0
    if (pct = 0)
        return UsageMonitorThemeRef("bad")    ; red
    if (pct < 20)
        return UsageMonitorThemeRef("warn")   ; yellow
    return UsageMonitorThemeRef("good")       ; teal / neon-green
}

; --- Change gates -----------------------------------------------------------
; Write a control only when the text differs from what was last written to it.
; GuiControl repaints unconditionally, so on a steady-state refresh (most auto
; ticks change nothing) the unguarded writes were the visible flicker. Returns
; true when a write actually happened, which is also the signal the adaptive
; cadence uses to decide whether anything is moving.
; Comparison is case-sensitive (==) because the text is user-visible.
UsageMonitorSetCtrlText(ctrlVar, newText)
{
    global usageMonitorLastCtrlText

    if (usageMonitorLastCtrlText.HasKey(ctrlVar) && usageMonitorLastCtrlText[ctrlVar] == newText)
        return false
    GuiControl, UsageMon:, %ctrlVar%, %newText%
    usageMonitorLastCtrlText[ctrlVar] := newText
    return true
}

; Record a themed color for a control, reporting whether it actually changed so the
; caller can skip the synchronous repaint when nothing did.
UsageMonitorSetCtrlColor(hwnd, colorRef)
{
    global usageMonitorCtrlColors

    if (!hwnd)
        return false
    if (usageMonitorCtrlColors.HasKey(hwnd) && usageMonitorCtrlColors[hwnd] = colorRef)
        return false
    usageMonitorCtrlColors[hwnd] := colorRef
    return true
}

; Progress bars are gated on (position, color) rather than text: PBM_SETPOS to the
; value a bar already holds still repaints it, and at a faster cadence that reads as
; a periodic twitch across the whole column.
UsageMonitorUpdateBar(hwnd, lineText)
{
    local colorRef, pct, usedPct, match, match1, barKey
    if (!hwnd)
        return false
    if (!RegExMatch(lineText, "(\d+)%", match))
    {
        colorRef := UsageMonitorThemeRef("dim")
        usedPct := 0
    }
    else
    {
        pct := match1 + 0
        usedPct := 100 - pct
        colorRef := UsageMonitorGetMetricColorRef(lineText)
    }
    barKey := usedPct . "|" . colorRef
    if (usageMonitorLastBarState.HasKey(hwnd) && usageMonitorLastBarState[hwnd] == barKey)
        return false
    SendMessage, 0x409, 0, colorRef,, ahk_id %hwnd%
    SendMessage, 0x402, usedPct, 0,, ahk_id %hwnd%
    usageMonitorLastBarState[hwnd] := barKey
    return true
}

UsageMonitorStartAnchorTracking()
{
    global usageMonitorAnchorTrackIntervalMs

    SetTimer, UsageMonitorTrackAnchor, Off
    SetTimer, UsageMonitorTrackAnchor, %usageMonitorAnchorTrackIntervalMs%
}

UsageMonitorStopAnchorTracking()
{
    SetTimer, UsageMonitorTrackAnchor, Off
}

; Start or stop only what differs between the current tier and the requested one, so it is cheap
; enough to call from every tracking tick.
UsageMonitorSetIdleTier(tier)
{
    local wasTicking, ticks

    if (!usageMonitorVisible)
        return
    if (tier = "away" && !UsageMonitorSetRawInputWake(true))
    {
        usageMonitorRawInputUnavailable := true
        tier := UsageMonitorDesiredIdleTier()
    }
    if (tier = "background")
        UsageMonitorSetPassthrough(false)   ; full view: keep taking the mouse so a hover can wake it
    if (tier = usageMonitorIdleTier)
        return

    wasTicking := (usageMonitorIdleTier = "active" || usageMonitorIdleTier = "hover")
    ticks := (tier = "active" || tier = "hover")
    usageMonitorIdleTier := tier

    if (ticks && !wasTicking)
        UsageMonitorStartAnchorTracking()
    else if (!ticks && wasTicking)
        UsageMonitorStopAnchorTracking()

    if (tier = "active")
    {
        SetTimer, UsageMonitorFocusBorderCheck, 200
        UsageMonitorResumeAutoRefresh()
    }
    else
    {
        SetTimer, UsageMonitorFocusBorderCheck, Off
        if (UsageMonitorTierRefreshes(tier))
            UsageMonitorResumeAutoRefresh()
        else
            SetTimer, UsageMonitorAutoRefreshTimer, Off
        if (tier != "away")
            UsageMonitorHideFocusBorder()
    }
    if (tier != "away")
        UsageMonitorSetRawInputWake(false)
}

; The tier the popup belongs in right now. Away wins, so a desk left with VS Code focused stops
; polling; otherwise focus decides, and a cursor resting on the popup keeps its hover effects live.
UsageMonitorDesiredIdleTier()
{
    local activeHwnd

    if (usageMonitorDragInProgress)
        return "active"
    if (!usageMonitorRawInputUnavailable && A_TimeIdle >= usageMonitorAwayAfterMs
        && A_TickCount - usageMonitorInputSeenTick >= usageMonitorAwayAfterMs)
        return "away"
    WinGet, activeHwnd, ID, A
    if (activeHwnd && (activeHwnd = usageMonitorHwnd || activeHwnd = usageMonitorResetsPanelHwnd))
        return "active"
    ; Docked, the tracked apps count as "using the popup". Floating, they are just other apps.
    ; Either way the popup still refreshes in the background tier (UsageMonitorTierRefreshes).
    if (!UsageMonitorScreenAnchorActive() && activeHwnd
        && (activeHwnd = usageMonitorLastTrackedHwnd || UsageMonitorIsTrackedAppWindow(activeHwnd)))
        return "active"
    if (usageMonitorShellHookUnavailable)
        return "active"   ; nothing could wake a background tier
    if (UsageMonitorCursorOverUncoveredPopup(activeHwnd))
        return "hover"
    return "background"
}

; True when the cursor is over the popup and the focused window is not covering that spot. The
; focused window sits above the popup in z-order, except the desktop, which is always below it.
UsageMonitorCursorOverUncoveredPopup(activeHwnd)
{
    local mx, my, ax, ay, aw, ah, activeClass

    CoordMode, Mouse, Screen
    MouseGetPos, mx, my
    if (!UsageMonitorPointInWindow(mx, my))
        return false
    if (!activeHwnd)
        return true
    WinGetClass, activeClass, ahk_id %activeHwnd%
    if (activeClass = "Progman" || activeClass = "WorkerW")
        return true
    WinGetPos, ax, ay, aw, ah, ahk_id %activeHwnd%
    return !(aw != "" && mx >= ax && mx < ax + aw && my >= ay && my < ay + ah)
}

; Back in the active tier: refresh now if the last snapshot is older than the cadence allows,
; otherwise pick the schedule up where it left off, so quick app switches cost no extra snapshot.
UsageMonitorResumeAutoRefresh()
{
    local delay, elapsed

    if (!usageMonitorVisible || usageMonitorFetchInFlight)
        return
    delay := UsageMonitorNextAutoRefreshMs()
    elapsed := usageMonitorLastFetchStartTick ? A_TickCount - usageMonitorLastFetchStartTick : delay
    if (elapsed >= delay)
        UsageMonitorRequestRefresh(true)
    else
        UsageMonitorScheduleAutoRefresh(delay - elapsed)
}

; No tracked window is left: hide but stay armed. The parked poll runs regardless of the SHELLHOOK
; listener, so a missed event (or a listener that could not register) never strands the popup.
UsageMonitorParkPopup()
{
    global usageMonitorVisible, usageMonitorParked, usageMonitorParkedPollMs

    if (UsageMonitorScreenAnchorActive())
        return   ; floating needs no tracked window, so it never parks
    UsageMonitorEnsureShellHook()
    if (usageMonitorVisible)
        HideUsageMonitorPopup(true)
    usageMonitorParked := true
    SetTimer, UsageMonitorParkedPollTimer, %usageMonitorParkedPollMs%
}

; Parked fallback: one anchor lookup. Re-shows as soon as any tracked window qualifies.
UsageMonitorParkedPoll()
{
    global usageMonitorVisible, usageMonitorParked

    if (!usageMonitorParked || usageMonitorVisible)
    {
        SetTimer, UsageMonitorParkedPollTimer, Off
        return
    }
    if (UsageMonitorGetAnchorWindow())
        ShowUsageMonitorPopup(true)
}

UsageMonitorEnsureShellHook()
{
    global usageMonitorShellHookMsg, usageMonitorShellHookUnavailable

    if (usageMonitorShellHookMsg)
        return true
    if (usageMonitorShellHookUnavailable)
        return false
    usageMonitorShellHookMsg := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
    OnMessage(usageMonitorShellHookMsg, "UsageMonitorOnShellHook")
    if (DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd))
        return true
    OnMessage(usageMonitorShellHookMsg, "UsageMonitorOnShellHook", 0)
    usageMonitorShellHookMsg := 0
    usageMonitorShellHookUnavailable := true
    return false
}

UsageMonitorReleaseShellHook()
{
    global usageMonitorShellHookMsg

    if (!usageMonitorShellHookMsg)
        return
    DllCall("DeregisterShellHookWindow", "Ptr", A_ScriptHwnd)
    OnMessage(usageMonitorShellHookMsg, "UsageMonitorOnShellHook", 0)
    usageMonitorShellHookMsg := 0
}

; SHELLHOOK notifications are posted, so this never blocks the window that sent them. It only arms
; UsageMonitorIdleWakeCheck, which coalesces a burst of window events into one check. The awake
; tiers ignore them: their tracking tick already watches focus.
UsageMonitorOnShellHook(wParam, lParam, msg, hwnd)
{
    local code

    ; 1 WINDOWCREATED, 2 WINDOWDESTROYED, 4 WINDOWACTIVATED (RUDEAPPACTIVATED 0x8004 once the high
    ; bit is masked off), 5 GETMINRECT: a window is minimizing or restoring, 6 REDRAW: a title
    ; changed. REDRAW matters only while parked: title-matched anchors (the Grok terminal, host
    ; dock apps) usually get their title after WINDOWCREATED, so that event alone arrives
    ; before the window qualifies. Awake tiers ignore it - tab titles redraw constantly.
    code := wParam & 0x7FFF
    if (usageMonitorParked && !usageMonitorVisible)
    {
        if (code < 1 || code > 6 || code = 3)
            return
        usageMonitorParkRetryStep := 1
        SetTimer, UsageMonitorIdleWakeTimer, -300
        return
    }
    if (code != 1 && code != 2 && code != 4 && code != 5)
        return
    if (usageMonitorIdleTier = "background" || usageMonitorIdleTier = "away")
        SetTimer, UsageMonitorIdleWakeTimer, -50
}

UsageMonitorIdleWakeCheck()
{
    global usageMonitorVisible, usageMonitorParked, usageMonitorIdleTier
    global usageMonitorParkRetryStep, usageMonitorParkRetryDelays

    if (!usageMonitorVisible)
    {
        if (!usageMonitorParked || ShowUsageMonitorPopup(true))
            return
        ; A restoring or launching window can still read as minimized, invisible, or untitled
        ; when its first events arrive, so walk a short retry ladder before giving up.
        if (usageMonitorParkRetryStep >= 1 && usageMonitorParkRetryStep <= usageMonitorParkRetryDelays.Length())
        {
            delay := usageMonitorParkRetryDelays[usageMonitorParkRetryStep]
            usageMonitorParkRetryStep += 1
            SetTimer, UsageMonitorIdleWakeTimer, -%delay%
        }
        return
    }

    UsageMonitorRememberPrevActiveWindow()
    if (usageMonitorIdleTier = "background" || usageMonitorIdleTier = "away")
    {
        ; One tracking pass while asleep: follow an anchor that moved, or park if none is left.
        UsageMonitorTrackWindowState()
        if (!usageMonitorVisible)
            return
        UsageMonitorApplyAnchor()
    }
    UsageMonitorSetIdleTier(UsageMonitorDesiredIdleTier())
}

; Away tier only: ask for raw keyboard and mouse input (RIDEV_INPUTSINK, so it arrives while
; another app has focus). Nothing is delivered until the user touches something, and the first
; message turns it off again, so being away costs nothing and coming back costs one message.
UsageMonitorSetRawInputWake(enable)
{
    local size, flags, target, devices

    enable := enable ? true : false
    if (enable = usageMonitorRawInputWakeActive)
        return true
    size := 8 + A_PtrSize                   ; RAWINPUTDEVICE: USHORT page, USHORT usage, DWORD flags, HWND target
    flags := enable ? 0x100 : 0x1           ; RIDEV_INPUTSINK : RIDEV_REMOVE
    target := enable ? A_ScriptHwnd : 0     ; RIDEV_REMOVE needs a null target
    VarSetCapacity(devices, size * 2, 0)
    NumPut(1, devices, 0, "UShort"), NumPut(2, devices, 2, "UShort")              ; generic desktop mouse
    NumPut(flags, devices, 4, "UInt"), NumPut(target, devices, 8, "Ptr")
    NumPut(1, devices, size, "UShort"), NumPut(6, devices, size + 2, "UShort")    ; generic desktop keyboard
    NumPut(flags, devices, size + 4, "UInt"), NumPut(target, devices, size + 8, "Ptr")
    if (enable)
        OnMessage(0x00FF, "UsageMonitorOnRawInput")   ; WM_INPUT
    if (!DllCall("RegisterRawInputDevices", "Ptr", &devices, "UInt", 2, "UInt", size))
    {
        if (enable)
            OnMessage(0x00FF, "UsageMonitorOnRawInput", 0)
        return false
    }
    if (!enable)
        OnMessage(0x00FF, "UsageMonitorOnRawInput", 0)
    usageMonitorRawInputWakeActive := enable
    return true
}

; Returns nothing, so WM_INPUT still reaches DefWindowProc, which frees the input buffer.
UsageMonitorOnRawInput(wParam, lParam, msg, hwnd)
{
    global usageMonitorInputSeenTick

    usageMonitorInputSeenTick := A_TickCount
    UsageMonitorSetRawInputWake(false)
    SetTimer, UsageMonitorIdleWakeTimer, -1
}

; "a|b|c" -> ["a", "b", "c"], dropping blank entries. Used for usageMonitorHostYieldWindows.
UsageMonitorSplitTitleList(list)
{
    local titles, item
    titles := []
    Loop, Parse, list, |
    {
        item := Trim(A_LoopField)
        if (item != "")
            titles.Push(item)
    }
    return titles
}

; True while any window the host asked the popup to yield z-order to exists.
UsageMonitorYieldWindowPresent()
{
    local index, title
    for index, title in usageMonitorYieldWindowTitles
    {
        if (WinExist(title))
            return true
    }
    return false
}

UsageMonitorTrackWindowState(yieldZOrder := false)
{
    global usageMonitorVisible, usageMonitorHwnd

    ; Floating: nothing to follow and nothing to park for. Stay on top, except while a
    ; yield-worthy overlay is up. Read the style first so a quiet tick makes no window calls.
    if (UsageMonitorScreenAnchorActive())
    {
        if (usageMonitorHwnd)
        {
            WinGet, exStyle, ExStyle, ahk_id %usageMonitorHwnd%
            if (yieldZOrder && (exStyle & 0x8))
                WinSet, AlwaysOnTop, Off, ahk_id %usageMonitorHwnd%
            else if (!yieldZOrder && !(exStyle & 0x8))
                WinSet, AlwaysOnTop, On, ahk_id %usageMonitorHwnd%
        }
        return
    }

    targetHwnd := UsageMonitorGetAnchorWindow()
    if (!targetHwnd)
    {
        UsageMonitorParkPopup()
        return
    }
    if (yieldZOrder)
    {
        if (usageMonitorHwnd)
            WinSet, AlwaysOnTop, Off, ahk_id %usageMonitorHwnd%
        return
    }

    ; Z-order: when a tracked app/popup is active keep AlwaysOnTop; otherwise slot popup
    ; just above its selected anchor so it stays visible without covering unrelated windows.
    if (usageMonitorHwnd)
    {
        WinGet, activeHwnd, ID, A
        if (UsageMonitorIsTrackedAppWindow(activeHwnd) || activeHwnd = usageMonitorHwnd)
        {
            WinSet, AlwaysOnTop, On, ahk_id %usageMonitorHwnd%
        }
        else
        {
            ; Find the window just above the anchor in z-order (GW_HWNDPREV = 3)
            prevAboveTarget := DllCall("GetWindow", "Ptr", targetHwnd, "UInt", 3, "Ptr")
            if (prevAboveTarget && prevAboveTarget != usageMonitorHwnd)
            {
                ; Place popup between prevAboveCode and VSCode — clears topmost flag automatically
                ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE = 0x0013
                DllCall("SetWindowPos", "Ptr", usageMonitorHwnd, "Ptr", prevAboveTarget, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
            }
            else if (!prevAboveTarget)
            {
                ; VSCode is at top of z-band — just remove topmost, which keeps popup near top
                WinSet, AlwaysOnTop, Off, ahk_id %usageMonitorHwnd%
            }
        }
    }
}

UsageMonitorGetPrimaryCodeWindow()
{
    return UsageMonitorGetBestAppWindow("Code.exe")
}

UsageMonitorGetAnchorWindow()
{
    global usageMonitorHwnd, usageMonitorLastTrackedHwnd, usageMonitorSuppressAnchorCapture, usageMonitorDockApps

    ; Normally: follow whichever tracked app (Claude / Codex / VS Code) is focused and
    ; remember it as the anchor. Skip this while a rebuild is suppressing capture so the
    ; transient foreground window (e.g. VS Code briefly surfacing) is not picked up.
    if (!usageMonitorSuppressAnchorCapture)
    {
        WinGet, activeHwnd, ID, A
        if (activeHwnd && activeHwnd != usageMonitorHwnd)
        {
            if (UsageMonitorIsTrackedAppWindow(activeHwnd) && UsageMonitorIsAnchorCandidateWindow(activeHwnd))
            {
                usageMonitorLastTrackedHwnd := activeHwnd
                return activeHwnd
            }
        }
    }

    ; Overlay itself (or an untracked app) is active: anchor to the last-focused tracked
    ; window. This is the fix for the toggle flash - during a toggle the overlay is active,
    ; so we re-stack against the remembered Claude/Codex/VS Code window, not a new pick.
    if (usageMonitorLastTrackedHwnd
        && WinExist("ahk_id " . usageMonitorLastTrackedHwnd)
        && UsageMonitorIsAnchorCandidateWindow(usageMonitorLastTrackedHwnd))
        return usageMonitorLastTrackedHwnd

    ; Fallback (cold start, or the remembered window was closed): fixed priority.
    claudeHwnd := UsageMonitorGetBestAppWindow("claude.exe")
    if (claudeHwnd)
        return claudeHwnd

    codexHwnd := UsageMonitorGetBestCodexWindow()
    if (codexHwnd)
        return codexHwnd

    ; The host's extra dock apps (usageMonitorHostDockApps), in the host's order.
    for dockIndex, dockApp in usageMonitorDockApps
    {
        dockHwnd := UsageMonitorGetBestDockAppWindow(dockApp)
        if (dockHwnd)
            return dockHwnd
    }

    grokTerminalHwnd := UsageMonitorGetBestGrokTerminalWindow()
    if (grokTerminalHwnd)
        return grokTerminalHwnd

    codeHwnd := UsageMonitorGetBestAppWindow("Code.exe")
    if (codeHwnd)
        return codeHwnd

    return 0
}

UsageMonitorGetBestAppWindow(processName)
{
    local appList, hwndCandidate, hwndBest
    local winX, winY, winW, winH, area, bestArea

    WinGet, appList, List, ahk_exe %processName%
    bestArea := 0
    hwndBest := 0

    Loop, %appList%
    {
        hwndCandidate := appList%A_Index%
        if (!hwndCandidate)
            continue

        if (!UsageMonitorIsAnchorCandidateWindow(hwndCandidate))
            continue

        WinGetPos, winX, winY, winW, winH, ahk_id %hwndCandidate%
        area := winW * winH
        if (area > bestArea)
        {
            bestArea := area
            hwndBest := hwndCandidate
        }
    }

    if (hwndBest)
        return hwndBest

    return 0
}

UsageMonitorGetBestCodexWindow()
{
    local codexHwnd, appList, hwndCandidate, hwndBest
    local winX, winY, winW, winH, area, bestArea

    ; Older Codex Desktop builds exposed Codex.exe directly. Current Store builds
    ; use ChatGPT.exe inside the OpenAI.Codex package, so distinguish that package
    ; from the separate ChatGPT Desktop app before accepting its window.
    codexHwnd := UsageMonitorGetBestAppWindow("Codex.exe")
    if (codexHwnd)
        return codexHwnd

    WinGet, appList, List, ahk_exe ChatGPT.exe
    bestArea := 0
    hwndBest := 0

    Loop, %appList%
    {
        hwndCandidate := appList%A_Index%
        if (!hwndCandidate)
            continue
        if (!UsageMonitorIsCodexWindow(hwndCandidate))
            continue
        if (!UsageMonitorIsAnchorCandidateWindow(hwndCandidate))
            continue

        WinGetPos, winX, winY, winW, winH, ahk_id %hwndCandidate%
        area := winW * winH
        if (area > bestArea)
        {
            bestArea := area
            hwndBest := hwndCandidate
        }
    }

    return hwndBest
}

UsageMonitorIsAnchorCandidateWindow(hwnd)
{
    local minMax, winX, winY, winW, winH, exStyle, ownerHwnd, style

    if (!hwnd)
        return false

    if (!DllCall("IsWindowVisible", "Ptr", hwnd))
        return false

    WinGet, minMax, MinMax, ahk_id %hwnd%
    if (minMax = -1)
        return false

    WinGetPos, winX, winY, winW, winH, ahk_id %hwnd%
    if (winW = "" || winW <= 0 || winH = "" || winH <= 0)
        return false

    WinGet, exStyle, ExStyle, ahk_id %hwnd%
    if (exStyle & 0x80)
        return false

    ; Reject owned windows (modal dialogs / popups, e.g. VS Code's external-link
    ; trust prompt). Real top-level app windows have no owner; dialogs do, so this
    ; keeps the overlay docked to the main editor instead of a transient dialog.
    ownerHwnd := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") ; GW_OWNER = 4
    if (ownerHwnd)
        return false

    ; Defense-in-depth: require a resizable window. The tracked main windows
    ; (Code / claude / Codex) all have WS_THICKFRAME; fixed-size dialogs do not.
    WinGet, style, Style, ahk_id %hwnd%
    if (!(style & 0x40000)) ; WS_THICKFRAME — skip non-resizable dialogs
        return false

    return true
}

UsageMonitorProcessNameEquals(processName, targetName)
{
    local processLower := "", targetLower := ""

    StringLower, processLower, processName
    StringLower, targetLower, targetName
    return (processLower = targetLower)
}

UsageMonitorIsTrackedAppProcess(processName)
{
    return UsageMonitorProcessNameEquals(processName, "Code.exe")
        || UsageMonitorProcessNameEquals(processName, "claude.exe")
        || UsageMonitorProcessNameEquals(processName, "Codex.exe")
}

UsageMonitorIsCodexWindow(hwnd)
{
    local procName, procPath, procPathLower

    WinGet, procName, ProcessName, ahk_id %hwnd%
    if (UsageMonitorProcessNameEquals(procName, "Codex.exe"))
        return true
    if (!UsageMonitorProcessNameEquals(procName, "ChatGPT.exe"))
        return false

    WinGet, procPath, ProcessPath, ahk_id %hwnd%
    ; The window can vanish between the two WinGet calls (e.g. while Codex is closing), leaving
    ; procPath blank. StringLower never assigns its output from a blank input, so #Warn would fire.
    if (procPath = "")
        return false
    StringLower, procPathLower, procPath
    return InStr(procPathLower, "\windowsapps\openai.codex_") > 0
}

; Terminal/console hosts can carry an app's name in their tab/window title (e.g. a PowerShell
; tab running that app's CLI). A title-matched dock app must never take the shell for the app
; window, so title matches exclude these processes; terminal matches require them.
UsageMonitorIsTerminalHostProcess(processName)
{
    return UsageMonitorProcessNameEquals(processName, "WindowsTerminal.exe")
        || UsageMonitorProcessNameEquals(processName, "WindowsTerminalPreview.exe")
        || UsageMonitorProcessNameEquals(processName, "powershell.exe")
        || UsageMonitorProcessNameEquals(processName, "pwsh.exe")
        || UsageMonitorProcessNameEquals(processName, "cmd.exe")
        || UsageMonitorProcessNameEquals(processName, "conhost.exe")
        || UsageMonitorProcessNameEquals(processName, "OpenConsole.exe")
}

UsageMonitorIsTrackedAppWindow(hwnd)
{
    local procName
    WinGet, procName, ProcessName, ahk_id %hwnd%
    if (UsageMonitorIsTrackedAppProcess(procName))
        return true
    if (UsageMonitorIsCodexWindow(hwnd))
        return true
    if (UsageMonitorIsGrokTerminalWindow(hwnd))
        return true
    return (UsageMonitorDockAppTypeFor(hwnd) != "")
}

UsageMonitorAnchorTypeFor(hwnd)
{
    local procName

    if (!hwnd)
        return ""

    WinGet, procName, ProcessName, ahk_id %hwnd%
    if (UsageMonitorProcessNameEquals(procName, "Code.exe"))
        return "vscode"
    if (UsageMonitorProcessNameEquals(procName, "claude.exe"))
        return "claude"
    if (UsageMonitorIsCodexWindow(hwnd))
        return "codex"
    if (UsageMonitorIsGrokTerminalWindow(hwnd))
        return "grok-terminal"
    return UsageMonitorDockAppTypeFor(hwnd)
}

; A WSL/Ubuntu terminal running the Grok dashboard: a terminal-host window whose title carries
; the configured Grok marker. Unlike a title-matched dock app (which excludes consoles), this one
; REQUIRES a terminal host so the HUD can dock to the shell where Grok work happens.
UsageMonitorIsGrokTerminalWindow(hwnd)
{
    global usageMonitorGrokTerminalTitleMatch
    if (usageMonitorGrokTerminalTitleMatch = "")
        return false
    WinGet, procName, ProcessName, ahk_id %hwnd%
    if (!UsageMonitorIsTerminalHostProcess(procName))
        return false
    WinGetTitle, winTitle, ahk_id %hwnd%
    return InStr(winTitle, usageMonitorGrokTerminalTitleMatch) > 0   ; InStr is case-insensitive by default
}

; Largest visible Grok-tagged terminal window (cold-start fallback for the anchor priority).
UsageMonitorGetBestGrokTerminalWindow()
{
    global usageMonitorGrokTerminalTitleMatch
    if (usageMonitorGrokTerminalTitleMatch = "")
        return 0

    WinGet, winList, List
    bestArea := 0
    hwndBest := 0
    Loop, %winList%
    {
        hwndCandidate := winList%A_Index%
        if (!hwndCandidate)
            continue
        if (!UsageMonitorIsGrokTerminalWindow(hwndCandidate))
            continue
        if (!UsageMonitorIsAnchorCandidateWindow(hwndCandidate))
            continue
        WinGetPos, winX, winY, winW, winH, ahk_id %hwndCandidate%
        area := winW * winH
        if (area > bestArea)
        {
            bestArea := area
            hwndBest := hwndCandidate
        }
    }
    return hwndBest
}

; Host dock apps (usageMonitorHostDockApps), parsed once at start: "type=kind:value|...". kind is
;   title:a,b     a window outside a terminal host whose title contains a or b (case-insensitive)
;   exe:name.exe  any window of that process
;   terminal:a,b  a terminal-host window whose title has a or b as a whole word
; type keys the app's saved position: lowercase letters, digits and "-", one entry per type. The
; built-in types, unknown kinds and malformed entries are skipped, so a typo never matches widely.
UsageMonitorParseDockApps(spec)
{
    local apps, seen, entry, eqPos, colonPos, appType, kind, value, values, item, words, index

    apps := []
    seen := {}
    Loop, Parse, spec, |
    {
        entry := Trim(A_LoopField)
        eqPos := InStr(entry, "=")
        colonPos := eqPos ? InStr(entry, ":", false, eqPos + 1) : 0
        if (eqPos < 2 || colonPos < eqPos + 2)
            continue
        appType := Trim(SubStr(entry, 1, eqPos - 1))
        kind := Trim(SubStr(entry, eqPos + 1, colonPos - eqPos - 1))
        value := RegExReplace(SubStr(entry, colonPos + 1), "[\x00-\x1f]", "")
        if (!RegExMatch(appType, "^[a-z][a-z0-9-]{0,23}$") || seen.HasKey(appType))
            continue
        if appType in vscode,claude,codex,grok-terminal,screen
            continue
        values := []
        Loop, Parse, value, `,
        {
            item := Trim(A_LoopField)
            if (kind = "terminal")
                item := RegExReplace(item, "[^A-Za-z0-9]", "")
            if (item != "")
                values.Push(item)
        }
        if (!values.Length())
            continue
        if (kind = "exe")
        {
            if (values.Length() != 1 || !RegExMatch(values[1], "i)^[A-Za-z0-9._ -]+[.]exe$"))
                continue
            apps.Push({type: appType, kind: "exe", values: values})
        }
        else if (kind = "title")
            apps.Push({type: appType, kind: "title", values: values})
        else if (kind = "terminal")
        {
            words := ""
            for index, item in values
                words .= (words = "" ? "" : "|") . item
            apps.Push({type: appType, kind: "terminal", values: values
                , pattern: "i)(^|[^A-Za-z0-9])(" . words . ")([^A-Za-z0-9]|$)"})
        }
        else
            continue
        seen[appType] := true
    }
    return apps
}

; Whether one parsed dock app matches a window's process name and title.
UsageMonitorDockAppMatches(app, procName, winTitle)
{
    local index, value

    if (app.kind = "exe")
        return UsageMonitorProcessNameEquals(procName, app.values[1])
    if (app.kind = "terminal")
        return UsageMonitorIsTerminalHostProcess(procName) && (RegExMatch(winTitle, app.pattern) > 0)
    if (UsageMonitorIsTerminalHostProcess(procName))
        return false
    for index, value in app.values
        if (InStr(winTitle, value))   ; InStr is case-insensitive by default
            return true
    return false
}

; The type of the first host dock app (in the host's order) that matches the window, or "".
UsageMonitorDockAppTypeFor(hwnd)
{
    local procName, winTitle, index, app

    if (!hwnd || !usageMonitorDockApps.Length())
        return ""
    WinGet, procName, ProcessName, ahk_id %hwnd%
    WinGetTitle, winTitle, ahk_id %hwnd%
    for index, app in usageMonitorDockApps
        if (UsageMonitorDockAppMatches(app, procName, winTitle))
            return app.type
    return ""
}

; Largest visible anchor-candidate window of one host dock app (cold-start fallback).
UsageMonitorGetBestDockAppWindow(app)
{
    local winList, hwndCandidate, hwndBest, procName, winTitle, winX, winY, winW, winH, area, bestArea

    WinGet, winList, List
    bestArea := 0
    hwndBest := 0
    Loop, %winList%
    {
        hwndCandidate := winList%A_Index%
        if (!hwndCandidate)
            continue
        WinGet, procName, ProcessName, ahk_id %hwndCandidate%
        WinGetTitle, winTitle, ahk_id %hwndCandidate%
        if (!UsageMonitorDockAppMatches(app, procName, winTitle))
            continue
        if (!UsageMonitorIsAnchorCandidateWindow(hwndCandidate))
            continue
        WinGetPos, winX, winY, winW, winH, ahk_id %hwndCandidate%
        area := winW * winH
        if (area > bestArea)
        {
            bestArea := area
            hwndBest := hwndCandidate
        }
    }
    return hwndBest
}

UsageMonitorResolveAnchorBounds(ByRef targetLeft, ByRef targetTop, ByRef targetRight, ByRef targetBottom)

{
    targetHwnd := UsageMonitorGetAnchorWindow()
    if (targetHwnd)
    {
        WinGetPos, anchorX, anchorY, anchorW, anchorH, ahk_id %targetHwnd%
        if (anchorW != "" && anchorW > 0 && anchorH != "" && anchorH > 0)
        {
            targetLeft := anchorX
            targetTop := anchorY
            targetRight := anchorX + anchorW
            targetBottom := anchorY + anchorH
            return true
        }
    }

    SysGet, targetMon, MonitorWorkArea, 1
    targetLeft := targetMonLeft
    targetTop := targetMonTop
    targetRight := targetMonRight
    targetBottom := targetMonBottom
    return (targetRight > targetLeft && targetBottom > targetTop)
}

UsageMonitorApplyAnchor()
{
    global usageMonitorHwnd
    global usageMonitorAnchorTarget, usageMonitorAnchorCorner
    global usageMonitorAnchorMarginX, usageMonitorAnchorMarginY
    global usageMonitorDragged, usageMonitorDragOffsetX, usageMonitorDragOffsetY
    global usageMonitorDragInProgress

    if (!usageMonitorHwnd)
        return false

    if (!WinExist("ahk_id " . usageMonitorHwnd))
        return false

    ; Don't fight Windows' modal drag loop — let the OS move the window unobstructed
    if (usageMonitorDragInProgress)
        return true

    UsageMonitorSyncPositionToAnchor()
    if (UsageMonitorScreenAnchorActive())
        return UsageMonitorApplyScreenAnchor()

    ; After a manual drag, track popup at its stored bottom-left offset from the selected anchor.
    if (usageMonitorDragged)
    {
        if (!UsageMonitorResolveAnchorBounds(targetLeft, targetTop, targetRight, targetBottom))
            return true
        WinGetPos, popupX, popupY, popupW, popupH, ahk_id %usageMonitorHwnd%
        if (popupW = "" || popupW <= 0 || popupH = "" || popupH <= 0)
            return true

        newX := targetLeft + usageMonitorDragOffsetX
        newY := targetBottom - popupH - usageMonitorDragOffsetY

        if (newX < targetLeft)
            newX := targetLeft
        if (newY < targetTop)
            newY := targetTop
        if (newX + popupW > targetRight)
            newX := targetRight - popupW
        if (newY + popupH > targetBottom)
            newY := targetBottom - popupH
        if (newX < targetLeft)
            newX := targetLeft
        if (newY < targetTop)
            newY := targetTop

        if (Abs(popupX - newX) > 1 || Abs(popupY - newY) > 1)
            WinMove, ahk_id %usageMonitorHwnd%,, %newX%, %newY%
        return true
    }

    WinGetPos, popupX, popupY, popupW, popupH, ahk_id %usageMonitorHwnd%
    if (popupW = "" || popupW <= 0 || popupH = "" || popupH <= 0)
        return false

    if (!UsageMonitorResolveAnchorBounds(targetLeft, targetTop, targetRight, targetBottom))
        return false

    if (usageMonitorAnchorCorner = "top-left")
    {
        newX := targetLeft + usageMonitorAnchorMarginX
        newY := targetTop + usageMonitorAnchorMarginY
    }
    else if (usageMonitorAnchorCorner = "bottom-left")
    {
        newX := targetLeft + usageMonitorAnchorMarginX
        newY := targetBottom - popupH - usageMonitorAnchorMarginY
    }
    else if (usageMonitorAnchorCorner = "bottom-right")
    {
        newX := targetRight - popupW - usageMonitorAnchorMarginX
        newY := targetBottom - popupH - usageMonitorAnchorMarginY
    }
    else
    {
        newX := targetRight - popupW - usageMonitorAnchorMarginX
        newY := targetTop + usageMonitorAnchorMarginY
    }

    if (newX < targetLeft)
        newX := targetLeft
    if (newY < targetTop)
        newY := targetTop
    if (newX + popupW > targetRight)
        newX := targetRight - popupW
    if (newY + popupH > targetBottom)
        newY := targetBottom - popupH
    if (newX < targetLeft)
        newX := targetLeft
    if (newY < targetTop)
        newY := targetTop

    if (popupX != "" && popupY != "")
    {
        if (Abs(popupX - newX) <= 1 && Abs(popupY - newY) <= 1)
            return true
    }

    WinMove, ahk_id %usageMonitorHwnd%,, %newX%, %newY%
    return true
}

; --- Screen anchor mode ---------------------------------------------------------
; Undragged, the popup sits in usageMonitorScreenCorner of the primary monitor's work area.
; Once dragged it keeps an absolute position instead of an offset from an anchor: the
; usageMonitorDragOffsetX/Y pair holds the popup's left edge and bottom edge in screen
; coordinates (bottom, so a full/mini switch keeps it hooked downward, as in apps mode), and
; the work area of whichever monitor holds that point clamps it. A monitor that disappears
; just lands it on the nearest one.

; Primary monitor work area. Deliberately assume-local (no declarations): SysGet's output
; pseudo-array (waLeft, waTop, ...) is then local. In an assume-global function it lands in
; globals even when declared local, and #Warn reports the declared locals as unset.
UsageMonitorPrimaryWorkArea(ByRef outLeft, ByRef outTop, ByRef outRight, ByRef outBottom)
{
    SysGet, wa, MonitorWorkArea
    outLeft := waLeft, outTop := waTop, outRight := waRight, outBottom := waBottom
}

UsageMonitorScreenAnchorPoint(ByRef px, ByRef py)
{
    local waLeft, waTop, waRight, waBottom

    if (usageMonitorDragged && usageMonitorAnchorType = "screen")
    {
        px := usageMonitorDragOffsetX + 1
        py := usageMonitorDragOffsetY - 1
        return
    }
    UsageMonitorPrimaryWorkArea(waLeft, waTop, waRight, waBottom)
    px := InStr(usageMonitorScreenCorner, "left") ? waLeft + usageMonitorScreenMarginX : waRight - usageMonitorScreenMarginX - 1
    py := InStr(usageMonitorScreenCorner, "top") ? waTop + usageMonitorScreenMarginY : waBottom - usageMonitorScreenMarginY - 1
}

UsageMonitorApplyScreenAnchor()
{
    local popupX, popupY, popupW, popupH, newX, newY, waLeft, waTop, waRight, waBottom

    WinGetPos, popupX, popupY, popupW, popupH, ahk_id %usageMonitorHwnd%
    if (popupW = "" || popupW <= 0 || popupH = "" || popupH <= 0)
        return false

    if (usageMonitorDragged)
    {
        newX := usageMonitorDragOffsetX
        newY := usageMonitorDragOffsetY - popupH
        UsageMonitorGetMonitorWorkAreaForRect(newX, newY, popupW, popupH, waLeft, waTop, waRight, waBottom)
    }
    else
    {
        UsageMonitorPrimaryWorkArea(waLeft, waTop, waRight, waBottom)
        newX := InStr(usageMonitorScreenCorner, "left") ? waLeft + usageMonitorScreenMarginX : waRight - popupW - usageMonitorScreenMarginX
        newY := InStr(usageMonitorScreenCorner, "top") ? waTop + usageMonitorScreenMarginY : waBottom - popupH - usageMonitorScreenMarginY
    }

    if (newX + popupW > waRight)
        newX := waRight - popupW
    if (newY + popupH > waBottom)
        newY := waBottom - popupH
    if (newX < waLeft)
        newX := waLeft
    if (newY < waTop)
        newY := waTop

    if (popupX != "" && popupY != "" && Abs(popupX - newX) <= 1 && Abs(popupY - newY) <= 1)
        return true
    WinMove, ahk_id %usageMonitorHwnd%,, %newX%, %newY%
    return true
}

UsageMonitorCaptureScreenPosition()
{
    local popX, popY, popW, popH

    WinGetPos, popX, popY, popW, popH, ahk_id %usageMonitorHwnd%
    if (popW = "" || popW <= 0 || popH = "" || popH <= 0)
        return false
    usageMonitorDragOffsetX := popX
    usageMonitorDragOffsetY := popY + popH
    usageMonitorDragged := true
    usageMonitorAnchorType := "screen"
    UsageMonitorPersistPositionForType("screen")
    return true
}

UsageMonitorTriggerRefresh(mode := "Snapshot", silent := false)
{
    global usageMonitorFetchInFlight, usageMonitorFetchPid, usageMonitorFetchMode, usageMonitorFetchStartTick
    global usageMonitorFetchOutFile, usageMonitorFetchStatusFile, usageMonitorLastFetchStartTick
    global usageMonitorClaudeProfile, usageMonitorFetchSilent
    global usageMonitorDir, usageMonitorDataDir
    global usageMonitorAddonActive, usageMonitorAddonModule

    if (usageMonitorFetchInFlight)
    {
        ; An automatic tick colliding with a still-running fetch is normal housekeeping,
        ; not something to report - it would otherwise paint an error on every tick once
        ; the cadence is faster than a slow snapshot.
        UsageMonitorScheduleAutoRefresh()
        if (!silent)
        {
            UsageMonitorSetState("Refresh already running...")
            UsageMonitorSetError("Refresh in progress.")
        }
        return false
    }

    workDir := usageMonitorDir
    scriptPath := workDir . "\Get-LLMUsageSnapshot.ps1"
    if (!FileExist(scriptPath))
    {
        UsageMonitorSetState("Error")
        UsageMonitorSetError("Setup error: scraper script not found.")
        return false
    }

    psExe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (!FileExist(psExe))
        psExe := "powershell.exe"

    ; Snapshot hand-off files live in the data folder, not %TEMP%: they carry the masked
    ; account label and Firefox profile names, and are deleted once read.
    tmpDir := usageMonitorDataDir . "\tmp"
    if (!InStr(FileExist(tmpDir), "D"))
        FileCreateDir, %tmpDir%
    modeArg := "Snapshot"
    outFile := tmpDir . "\llm-usage-out-" . A_Now . "-" . A_TickCount . ".txt"
    statusFile := tmpDir . "\llm-usage-status-" . A_Now . "-" . A_TickCount . ".txt"
    FileDelete, %outFile%
    FileDelete, %statusFile%

    runTarget := """" . psExe . """ -NoProfile -ExecutionPolicy Bypass -File """ . scriptPath . """ -Mode " . modeArg
        . " -OutFile """ . outFile . """ -StatusFile """ . statusFile . """ -DataDir """ . usageMonitorDataDir . """"
    safeClaudeProfile := UsageMonitorSafeProfileName(usageMonitorClaudeProfile)
    if (safeClaudeProfile != "")
        runTarget := runTarget . " -ClaudeProfile """ . safeClaudeProfile . """"
    ; The Settings window's per-provider choices, re-read so a Save from the other host counts.
    UsageMonitorLoadProviderPrefs()
    runTarget := runTarget . " -Providers """ . UsageMonitorProvidersArg() . """"
    ; The host's add-on module (usageMonitorHostAddonModule, copied once at start). A path that
    ; could break out of its quotes is never put on the command line; the bridge gets a word it
    ; rejects instead, and the add-on row shows the error.
    if (usageMonitorAddonActive)
        runTarget := runTarget . " -AddonModule """ . (RegExMatch(usageMonitorAddonModule, "^[A-Za-z]:[\\][^""]+[.]mjs$") ? usageMonitorAddonModule : "rejected") . """"

    Run, %runTarget%, %workDir%, Hide UseErrorLevel, launchPid
    if (ErrorLevel = "ERROR" || launchPid = 0)
    {
        UsageMonitorSetState("Error")
        UsageMonitorSetError("Could not start refresh.")
        return false
    }

    usageMonitorFetchInFlight := true
    usageMonitorFetchPid := launchPid
    usageMonitorFetchOutFile := outFile
    usageMonitorFetchStatusFile := statusFile
    usageMonitorFetchMode := modeArg
    usageMonitorFetchStartTick := A_TickCount
    usageMonitorLastFetchStartTick := usageMonitorFetchStartTick
    usageMonitorFetchSilent := silent
    UsageMonitorScheduleAutoRefresh()
    if (!silent)
    {
        UsageMonitorSetError("")
        UsageMonitorSetState("Refreshing...")
    }
    SetTimer, UsageMonitorPollSnapshot, 200
    return true
}

UsageMonitorValue(snapshot, key, defaultValue := "")
{
    if (IsObject(snapshot) && snapshot.HasKey(key))
        return snapshot[key]
    return defaultValue
}

UsageMonitorClaudeHeaderText(snapshot)
{
    return "Claude"
}

UsageMonitorClaudeAccountSwitchEnabled()
{
    global usageMonitorShowClaudeAccountFull, usageMonitorViewMode
    global usageMonitorClaudeProfileSwitchAvailable, usageMonitorClaudeNextProfile

    return (usageMonitorViewMode = "full"
        && usageMonitorShowClaudeAccountFull
        && usageMonitorClaudeProfileSwitchAvailable
        && usageMonitorClaudeNextProfile != "")
}

UsageMonitorUpdateClaudeProfileState(snapshot)
{
    global usageMonitorClaudeProfile, usageMonitorClaudeProfileChoices
    global usageMonitorClaudeNextProfile, usageMonitorClaudeProfileSwitchAvailable

    snapshotProfile := UsageMonitorSafeProfileName(UsageMonitorValue(snapshot, "claude_profile", ""))
    if (snapshotProfile != "")
    {
        usageMonitorClaudeProfile := snapshotProfile
        UsageMonitorPersistClaudeProfile()
    }

    usageMonitorClaudeProfileChoices := UsageMonitorValue(snapshot, "claude_profile_choices", "")
    usageMonitorClaudeNextProfile := UsageMonitorSafeProfileName(UsageMonitorValue(snapshot, "claude_next_profile", ""))
    usageMonitorClaudeProfileSwitchAvailable := (UsageMonitorValue(snapshot, "claude_profile_switch_available", "0") = "1"
        && usageMonitorClaudeNextProfile != "")
}

; Which login supplied a provider's numbers (<provider>_source in the snapshot, written by the
; scraper's CLI-first loaders): the short word for the full view's dim source tag.
UsageMonitorSourceTagText(source)
{
    if (source = "cli")
        return "CLI"
    if (source = "firefox")
        return "Firefox"
    return ""
}

; The add-on's tag is the module's own word (a-z, up to 8 characters), shown as it is.
UsageMonitorAddonSourceTagText(source)
{
    return RegExMatch(source, "^[a-z]{1,8}$") ? source : ""
}

UsageMonitorClaudeSourceIsCli()
{
    global usageMonitorLastSnapshot
    return IsObject(usageMonitorLastSnapshot) && UsageMonitorValue(usageMonitorLastSnapshot, "claude_source", "") = "cli"
}

; Full view only: the dim tag beside the Codex, Grok and add-on headers. Claude's source shows in
; its account-label slot instead (UsageMonitorUpdateClaudeAccountDisplay). Returns true when a
; tag's text changed.
UsageMonitorUpdateSourceTags(snapshot)
{
    global usageMonitorHwndCodexSource, usageMonitorHwndGrokSource, usageMonitorHwndAddonSource

    changed := false
    if (usageMonitorHwndCodexSource && UsageMonitorSetCtrlText("UsageMonCodexSource", UsageMonitorSourceTagText(UsageMonitorValue(snapshot, "codex_source", ""))))
        changed := true
    if (usageMonitorHwndGrokSource && UsageMonitorSetCtrlText("UsageMonGrokSource", UsageMonitorSourceTagText(UsageMonitorValue(snapshot, "grok_source", ""))))
        changed := true
    if (usageMonitorHwndAddonSource && UsageMonitorSetCtrlText("UsageMonAddonSource", UsageMonitorAddonSourceTagText(UsageMonitorValue(snapshot, "addon_source", ""))))
        changed := true
    return changed
}

; The account label is registered as a button (it switches accounts). While it shows the CLI tag it
; is only a hover target for its tooltip, so its hover and pressed colors match its resting ones.
UsageMonitorSetClaudeAccountTagLook(isTag)
{
    global usageMonitorButtons, usageMonitorHwndClaudeAccount

    if (!usageMonitorHwndClaudeAccount || !usageMonitorButtons.HasKey(usageMonitorHwndClaudeAccount))
        return
    btn := usageMonitorButtons[usageMonitorHwndClaudeAccount]
    btn.hoverText := isTag ? UsageMonitorThemeRef("dim") : UsageMonitorThemeRef("strong")
    btn.pressedText := btn.hoverText
    btn.hoverBg := isTag ? UsageMonitorThemeRef("bg") : UsageMonitorThemeRef("btnHover")
    btn.pressedBg := isTag ? UsageMonitorThemeRef("bg") : UsageMonitorThemeRef("btnPressed")
}

; Gated on (visible-state, text, switch-enabled) rather than routed through the shared
; text cache, because a single call also drives Show/Hide, the button visual and an
; explicit InvalidateRect. Returns true when it actually touched the control.
UsageMonitorUpdateClaudeAccountDisplay(snapshot)
{
    global usageMonitorShowClaudeAccountFull, usageMonitorViewMode
    global usageMonitorHwndClaudeAccount, usageMonitorCtrlColors
    global usageMonitorLastAccountDisplay

    if (!usageMonitorHwndClaudeAccount)
        return false

    ; Claude Code's login supplied Claude: there is no account email (the login file holds none),
    ; so the slot shows the source tag "CLI", dim and in the tags' font, whatever the eye state
    ; (owner decision, 2026-10-26). Switching accounts is a Firefox-path feature and is off meanwhile.
    if (usageMonitorViewMode = "full" && UsageMonitorValue(snapshot, "claude_source", "") = "cli")
    {
        if (usageMonitorLastAccountDisplay == "cli")
            return false
        usageMonitorLastAccountDisplay := "cli"
        Gui, UsageMon:Font, % "s" . UsFont(8) . " Norm c" . UsageMonitorThemeRgb("dim"), Segoe UI
        GuiControl, UsageMon:Font, UsageMonClaudeAccount
        GuiControl, UsageMon:, UsageMonClaudeAccount, CLI
        GuiControl, UsageMon:Show, UsageMonClaudeAccount
        usageMonitorCtrlColors[usageMonitorHwndClaudeAccount] := UsageMonitorThemeRef("dim")
        UsageMonitorSetClaudeAccountTagLook(true)
        UsageMonitorSetButtonDefaultVisual(usageMonitorHwndClaudeAccount, usageMonitorCtrlColors[usageMonitorHwndClaudeAccount])
        UsageMonitorRefreshButtonBaseRect(usageMonitorHwndClaudeAccount)
        DllCall("InvalidateRect", "Ptr", usageMonitorHwndClaudeAccount, "Ptr", 0, "Int", true)
        return true
    }
    ; Leaving the CLI tag: restore the account label's own font and button colors.
    if (usageMonitorLastAccountDisplay == "cli")
    {
        Gui, UsageMon:Font, % "s" . UsFont(9) . " Norm Bold c" . UsageMonitorThemeRgb("text"), Segoe UI
        GuiControl, UsageMon:Font, UsageMonClaudeAccount
        UsageMonitorSetClaudeAccountTagLook(false)
    }

    accountLabel := UsageMonitorValue(snapshot, "claude_account_label", "")
    if (usageMonitorViewMode = "full" && usageMonitorShowClaudeAccountFull && accountLabel != "")
    {
        accountText := UsageMonitorTruncateText(accountLabel, 28)
        switchEnabled := UsageMonitorClaudeAccountSwitchEnabled() ? "1" : "0"
        displayKey := "show|" . switchEnabled . "|" . accountText
        if (usageMonitorLastAccountDisplay == displayKey)
            return false
        usageMonitorLastAccountDisplay := displayKey
        GuiControl, UsageMon:, UsageMonClaudeAccount, %accountText%
        GuiControl, UsageMon:Show, UsageMonClaudeAccount
        usageMonitorCtrlColors[usageMonitorHwndClaudeAccount] := (switchEnabled = "1") ? UsageMonitorThemeRef("text") : UsageMonitorThemeRef("dim")
        UsageMonitorSetButtonDefaultVisual(usageMonitorHwndClaudeAccount, usageMonitorCtrlColors[usageMonitorHwndClaudeAccount])
        UsageMonitorRefreshButtonBaseRect(usageMonitorHwndClaudeAccount)
        DllCall("InvalidateRect", "Ptr", usageMonitorHwndClaudeAccount, "Ptr", 0, "Int", true)
        return true
    }

    if (usageMonitorLastAccountDisplay == "hide")
        return false
    usageMonitorLastAccountDisplay := "hide"
    GuiControl, UsageMon:Hide, UsageMonClaudeAccount
    return true
}

UsageMonitorSwitchClaudeAccount()
{
    global usageMonitorVisible, usageMonitorFetchInFlight
    global usageMonitorClaudeProfile, usageMonitorClaudeNextProfile

    if (!usageMonitorVisible)
        return false
    ; A click on the CLI tag (Claude Code's login supplies Claude) switches nothing, and neither
    ; does one while Settings keeps Claude off Firefox.
    if (UsageMonitorClaudeSourceIsCli() || UsageMonitorProviderPref("claude") = "off" || UsageMonitorProviderPref("claude") = "cli")
        return false
    if (usageMonitorFetchInFlight)
    {
        UsageMonitorSetError("Refresh in progress.")
        return false
    }
    if (!UsageMonitorClaudeAccountSwitchEnabled())
    {
        UsageMonitorSetError("No second Claude account available.")
        return false
    }

    nextProfile := UsageMonitorSafeProfileName(usageMonitorClaudeNextProfile)
    if (nextProfile = "")
    {
        UsageMonitorSetError("No second Claude account available.")
        return false
    }

    usageMonitorClaudeProfile := nextProfile
    UsageMonitorPersistClaudeProfile()
    UsageMonitorSetError("Switching Claude account...")
    return UsageMonitorRequestRefresh()
}

UsageMonitorKeyboardSwitchClaudeAccount()
{
    global usageMonitorVisible, usageMonitorFetchInFlight
    global usageMonitorClaudeProfile, usageMonitorClaudeNextProfile
    global usageMonitorClaudeProfileSwitchAvailable

    if (!usageMonitorVisible)
        return false
    ; Account switching cycles Firefox profiles, so it does nothing while Settings keeps Claude off
    ; Firefox, or while Claude Code's login supplies Claude.
    if (UsageMonitorProviderPref("claude") = "off")
    {
        UsageMonitorSetError("Claude is off in Settings.")
        return false
    }
    if (UsageMonitorProviderPref("claude") = "cli")
    {
        UsageMonitorSetError("Claude is set to CLI only in Settings; nothing to switch.")
        return false
    }
    if (UsageMonitorClaudeSourceIsCli())
    {
        UsageMonitorSetError("Claude uses the Claude Code login; nothing to switch.")
        return false
    }
    if (usageMonitorFetchInFlight)
    {
        UsageMonitorSetError("Refresh in progress.")
        return false
    }
    if (!usageMonitorClaudeProfileSwitchAvailable || usageMonitorClaudeNextProfile = "")
    {
        UsageMonitorSetError("No second Claude account available.")
        return false
    }

    nextProfile := UsageMonitorSafeProfileName(usageMonitorClaudeNextProfile)
    if (nextProfile = "")
    {
        UsageMonitorSetError("No second Claude account available.")
        return false
    }

    usageMonitorClaudeProfile := nextProfile
    UsageMonitorPersistClaudeProfile()
    UsageMonitorSetError("Switching Claude account...")
    return UsageMonitorRequestRefresh()
}

UsageMonitorToggleResetDates()
{
    global usageMonitorShowResetDates, usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus

    usageMonitorShowResetDates := !usageMonitorShowResetDates
    UsageMonitorUpdateResetToggleText()
    if (IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
}

; View-aware [T] dispatcher: full view keeps the persisted inline Resets toggle; mini view
; shows a transient resets panel (toggling it off if already up) without mutating any state.
UsageMonitorHandleResetsKey()
{
    global usageMonitorViewMode, usageMonitorResetsPanelVisible

    if (usageMonitorViewMode = "mini")
    {
        if (usageMonitorResetsPanelVisible)
            UsageMonitorHideMiniResetsPanel()
        else
            UsageMonitorShowMiniResetsPanel()
        return
    }
    UsageMonitorToggleResetDates()
}

; One "Label — reset" line for the mini resets panel; em dash placeholder when unknown.
UsageMonitorFormatResetLine(label, resetText)
{
    local sep
    sep := " " . Chr(0x2014) . " "
    if (resetText = "")
        resetText := Chr(0x2014)
    return label . sep . resetText
}

; Find the work area of the monitor under a screen rect's center (fallback: monitor 1).
UsageMonitorGetMonitorWorkAreaForRect(rx, ry, rw, rh, ByRef waLeft, ByRef waTop, ByRef waRight, ByRef waBottom)
{
    local cx, cy, count, i
    cx := rx + (rw // 2)
    cy := ry + (rh // 2)
    SysGet, count, MonitorCount
    i := 1
    while (i <= count)
    {
        SysGet, mon, MonitorWorkArea, %i%
        if (cx >= monLeft && cx < monRight && cy >= monTop && cy < monBottom)
        {
            waLeft := monLeft, waTop := monTop, waRight := monRight, waBottom := monBottom
            return
        }
        i += 1
    }
    SysGet, mon, MonitorWorkArea, 1
    waLeft := monLeft, waTop := monTop, waRight := monRight, waBottom := monBottom
}

; Mini-view transient resets panel: a themed dark panel docked flush beneath the HUD
; (auto-flipping above when there's no room below), auto-hiding after 8s.
;
; It lists the resets for exactly the providers the mini view is currently showing.
; It used to hard-code four lines - Codex D/W and Claude D/W - which was wrong in both
; directions: Grok was never listed even while its column was on screen, and Codex was
; always listed even when hidden or auto-suppressed, so [T] reported resets for a
; provider the user could not see.
UsageMonitorShowMiniResetsPanel()
{
    global usageMonitorHwnd, usageMonitorLastSnapshot
    global usageMonitorResetsPanelHwnd, usageMonitorResetsPanelVisible
    global usageMonitorMiniShownCodexDaily, usageMonitorMiniShownCodexWeekly
    global usageMonitorMiniShownClaudeDaily, usageMonitorMiniShownClaudeWeekly
    global usageMonitorMiniShownClaudeFable
    global usageMonitorMiniShownGrokWeekly
    global usageMonitorMiniShownAddonLine1, usageMonitorMiniShownAddonLine2
    global UsageMonResetsText   ; Gui control var must be global/static, not a function local

    if (!usageMonitorHwnd || !WinExist("ahk_id " . usageMonitorHwnd))
        return

    snap := usageMonitorLastSnapshot
    haveSnap := IsObject(snap)
    lines := []
    ; Keyed on the per-LINE flags, not the per-provider ones. Codex commonly shows
    ; its weekly line only (promoted into the daily row), and keying on the provider
    ; listed a "Codex D" reset for a line that was not on screen.
    if (usageMonitorMiniShownCodexDaily)
        lines.Push(UsageMonitorFormatResetLine("Codex D", haveSnap ? UsageMonitorValue(snap, "codex_line_1_reset_text", "") : ""))
    if (usageMonitorMiniShownCodexWeekly)
        lines.Push(UsageMonitorFormatResetLine("Codex W", haveSnap ? UsageMonitorValue(snap, "codex_line_2_reset_text", "") : ""))
    if (usageMonitorMiniShownClaudeDaily)
        lines.Push(UsageMonitorFormatResetLine("Claude D", haveSnap ? UsageMonitorValue(snap, "claude_line_1_reset_text", "") : ""))
    if (usageMonitorMiniShownClaudeWeekly)
        lines.Push(UsageMonitorFormatResetLine("Claude W", haveSnap ? UsageMonitorValue(snap, "claude_line_2_reset_text", "") : ""))
    ; Per-model scoped row: label letter derived from the line's model name (Fable -> "Claude F")
    ; so the panel matches whatever initial the mini column renders.
    if (usageMonitorMiniShownClaudeFable)
    {
        fableLine := haveSnap ? UsageMonitorValue(snap, "claude_line_3", "") : ""
        lines.Push(UsageMonitorFormatResetLine("Claude " . UsageMonitorMetricLinePrefix(fableLine)
            , haveSnap ? UsageMonitorValue(snap, "claude_line_3_reset_text", "") : ""))
    }
    ; Labelled "Grok W" to match the mini column, which renders "W:" - the control is
    ; named GrokMonthly but the user-facing unit is weekly.
    if (usageMonitorMiniShownGrokWeekly)
        lines.Push(UsageMonitorFormatResetLine("Grok W", haveSnap ? UsageMonitorValue(snap, "grok_line_1_reset_text", "") : ""))
    ; The add-on's rows: label letters from its own line text, as the mini column renders them.
    if (usageMonitorMiniShownAddonLine1)
        lines.Push(UsageMonitorFormatResetLine(UsageMonitorAddonDisplayLabel() . " " . UsageMonitorMetricLinePrefix(haveSnap ? UsageMonitorValue(snap, "addon_line_1", "") : "")
            , haveSnap ? UsageMonitorValue(snap, "addon_line_1_reset_text", "") : ""))
    if (usageMonitorMiniShownAddonLine2)
        lines.Push(UsageMonitorFormatResetLine(UsageMonitorAddonDisplayLabel() . " " . UsageMonitorMetricLinePrefix(haveSnap ? UsageMonitorValue(snap, "addon_line_2", "") : "")
            , haveSnap ? UsageMonitorValue(snap, "addon_line_2_reset_text", "") : ""))

    ; Every provider hidden: say so rather than making [T] look broken.
    if (!lines.Length())
        lines.Push("No providers shown")
    body := ""
    for idx, lineText in lines
        body .= (idx = 1 ? "" : "`n") . lineText

    WinGetPos, hudX, hudY, hudW, hudH, ahk_id %usageMonitorHwnd%
    if (hudW = "" || hudW <= 0)
        return

    textW := hudW - UsScale(12)
    if (textW < UsScale(40))
        textW := UsScale(40)

    ; Rebuild rather than reuse. A Text control keeps the height it was created with,
    ; and the body is now 1-5 lines instead of always 4, so a cached control would clip
    ; the taller cases and leave dead space in the shorter ones.
    if (usageMonitorResetsPanelHwnd)
    {
        Gui, UsageMonResets:Destroy
        usageMonitorResetsPanelHwnd := 0
    }
    ; -DPIScale: panel width/dock math mixes WinGetPos physicals with control sizes.
    Gui, UsageMonResets:New, +AlwaysOnTop +ToolWindow -Caption -DPIScale +HwndusageMonitorResetsPanelHwnd
    Gui, UsageMonResets:Color, % UsageMonitorThemeRgb("bg"), % UsageMonitorThemeRgb("bg")
    Gui, UsageMonResets:Margin, % UsScale(6), % UsScale(5)
    Gui, UsageMonResets:Font, % "s" . UsFont(9) . " c" . UsageMonitorThemeRgb("text"), Segoe UI
    Gui, UsageMonResets:Add, Text, % "w" . textW . " vUsageMonResetsText", % body

    ; Realize size to measure the panel height, then place at HUD width. WinGetPos needs
    ; DetectHiddenWindows On since the panel is shown hidden (mirrors the sprite-sizing code).
    prevDetectHidden := A_DetectHiddenWindows
    DetectHiddenWindows, On
    Gui, UsageMonResets:Show, AutoSize Hide
    WinGetPos, , , panelW, panelH, ahk_id %usageMonitorResetsPanelHwnd%
    DetectHiddenWindows, %prevDetectHidden%
    panelW := hudW

    UsageMonitorGetMonitorWorkAreaForRect(hudX, hudY, hudW, hudH, waLeft, waTop, waRight, waBottom)

    gap := UsScale(2)
    belowY := hudY + hudH + gap
    aboveY := hudY - panelH - gap
    if (belowY + panelH <= waBottom)
        panelY := belowY
    else if (aboveY >= waTop)
        panelY := aboveY
    else
        panelY := belowY

    panelX := hudX
    if (panelX + panelW > waRight)
        panelX := waRight - panelW
    if (panelX < waLeft)
        panelX := waLeft

    Gui, UsageMonResets:Show, % "x" . panelX . " y" . panelY . " w" . panelW . " h" . panelH . " NoActivate"
    usageMonitorResetsPanelVisible := true
    SetTimer, UsageMonitorMiniResetsPanelTimeout, -8000
}

UsageMonitorHideMiniResetsPanel()
{
    global usageMonitorResetsPanelHwnd, usageMonitorResetsPanelVisible

    SetTimer, UsageMonitorMiniResetsPanelTimeout, Off
    if (usageMonitorResetsPanelHwnd)
        Gui, UsageMonResets:Hide
    usageMonitorResetsPanelVisible := false
}

; Full-view: flip the account-label visibility (independent of Resets), persist, repaint.
UsageMonitorToggleClaudeAccountFull()
{
    global usageMonitorShowClaudeAccountFull, usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus

    usageMonitorShowClaudeAccountFull := !usageMonitorShowClaudeAccountFull
    UsageMonitorPersistShowClaudeAccountFull()
    UsageMonitorUpdateClaudeAccountToggleGlyph()
    if (IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
}

; Mini-view: flip the account-signal visibility, persist, re-layout the mini columns.
UsageMonitorToggleClaudeAccountMini()
{
    global usageMonitorShowClaudeAccountMini, usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus

    usageMonitorShowClaudeAccountMini := !usageMonitorShowClaudeAccountMini
    UsageMonitorPersistShowClaudeAccountMini()
    if (IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
}

; Dispatcher for the [A] key: toggle the active view's account display.
UsageMonitorToggleAccountDisplay()
{
    global usageMonitorViewMode

    if (usageMonitorViewMode = "mini")
        UsageMonitorToggleClaudeAccountMini()
    else
        UsageMonitorToggleClaudeAccountFull()
}

UsageMonitorAppendReset(lineText, resetText)
{
    if (resetText = "" || InStr(lineText, "unavailable") || InStr(lineText, "n/a") || UsageMonitorIsNoSubscriptionLine(lineText))
        return lineText
    return lineText . " - " . resetText
}

UsageMonitorLineIsZero(lineText)
{
    local match, match1
    if (!RegExMatch(lineText, "(\d+)%", match))
        return false
    return (match1 + 0) = 0
}

UsageMonitorBuildRefreshFallbackError(snapshot, baseText)
{
    currentError := UsageMonitorValue(snapshot, "error", "")
    if (currentError = "")
        return baseText

    StringLower, lowerError, currentError
    if (InStr(lowerError, "fetch failed") || InStr(lowerError, "request timed out") || InStr(lowerError, "could not determine api url"))
        return baseText . " Network/API unavailable."

    return baseText . " " . UsageMonitorTruncateText(currentError, 85)
}

UsageMonitorTruncateText(text, maxChars)
{
    maxChars := maxChars + 0
    if (maxChars <= 3 || StrLen(text) <= maxChars)
        return text
    return SubStr(text, 1, maxChars - 3) . "..."
}

; Compact active-account code for the mini signal, derived from the masked label
; (head***tail -> head+tail), e.g. "j***42@example.com" -> "j42@". Empty if unknown.
UsageMonitorClaudeAccountShort(snapshot)
{
    local label, localPart, short
    label := UsageMonitorValue(snapshot, "claude_account_label", "")
    if (label = "")
        return ""
    localPart := StrSplit(label, "@")[1]
    short := StrReplace(localPart, "***", "")
    short := Trim(short, " `t`r`n")
    if (short = "")
        return ""
    return UsageMonitorTruncateText(short, 5) . "@"
}

; First letter of the line's leading label word (Daily->D, Weekly->W, Monthly->M, Fable->F),
; so per-model scoped lines compact to their model's initial without a hardcoded list.
UsageMonitorMetricLinePrefix(lineText)
{
    local labelMatch, labelMatch1

    if (RegExMatch(lineText, "^\s*([A-Za-z])[A-Za-z0-9 ]*:", labelMatch))
        return Format("{:U}", labelMatch1)
    return "D"
}

UsageMonitorCompactMetricLine(lineText)
{
    local prefix, pctText

    prefix := UsageMonitorMetricLinePrefix(lineText)
    if (RegExMatch(lineText, "\d+%", pctText))
        return prefix . ":" . pctText
    if (UsageMonitorIsNoSubscriptionLine(lineText))
        return prefix . ":no sub"
    if (InStr(lineText, "unavailable") || InStr(lineText, "n/a"))
        return prefix . ":n/a"
    return prefix . ":-"
}

UsageMonitorIsNoSubscriptionLine(value)
{
    local trimmedValue, lowerValue

    trimmedValue := Trim(value, " `t`r`n")
    if (trimmedValue = "")
        return false

    StringLower, lowerValue, trimmedValue
    return InStr(lowerValue, "no subscription")
}

; A metric line carries usable data only if it has a concrete percentage (incl. 0%).
; Lines that are n/a, unavailable, No Subscription, or "-" have no percent — in mini
; view those provider columns are collapsed entirely (see UsageMonitorSetMiniProvidersVisible)
; rather than showing a dead "X:n/a" cell.
UsageMonitorLineHasPercent(lineText)
{
    return RegExMatch(lineText, "\d+%") ? true : false
}

UsageMonitorSetMiniProvidersVisible(showCodex, showClaude, showGrok
    , showCodexDaily, showCodexWeekly, showClaudeDaily, showClaudeWeekly, showGrokMonthly
    , claudeNoSubscription, grokNoSubscription := false, showClaudeFable := false
    , showAddon := false, showAddonLine1 := false, showAddonLine2 := false, addonNoSubscription := false)
{
    global usageMonitorViewMode, usageMonitorVisible, usageMonitorHwndViewToggleBtn
    global usageMonitorShowClaudeAccountMini, usageMonitorClaudeAccountShort
    global usageMonitorHwndClaudeAccountSignal, UsageMonClaudeAccountSignal
    global usageMonitorMiniSignalActive, usageMonitorMiniDotShown
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode
    global usageMonitorMiniShownCodex, usageMonitorMiniShownClaude, usageMonitorMiniShownGrok
    global usageMonitorMiniShownCodexDaily, usageMonitorMiniShownCodexWeekly
    global usageMonitorMiniShownClaudeDaily, usageMonitorMiniShownClaudeWeekly
    global usageMonitorMiniShownClaudeFable
    global usageMonitorMiniShownGrokWeekly
    global usageMonitorHwndMiniHideCodex, usageMonitorHwndMiniHideClaude, usageMonitorHwndMiniHideGrok
    global usageMonitorMiniAddonMode, usageMonitorMiniShownAddon
    global usageMonitorMiniShownAddonLine1, usageMonitorMiniShownAddonLine2, usageMonitorHwndMiniHideAddon
    global usageMonitorOffCodex, usageMonitorOffClaude, usageMonitorOffGrok, usageMonitorOffAddon
    global usageMonitorAddonActive

    if (usageMonitorViewMode != "mini")
        return

    leftX := UsScale(4)
    colW := UsScale(48)
    lineH := UsScale(18)
    stride := colW + UsScale(14)    ; column pitch (must match build: colW + gap+divider+gap)
    yHead := UsScale(3)
    yDaily := yHead + lineH
    yWeekly := yDaily + lineH
    yFable := yWeekly + lineH
    ; Off-layout parking spot for a collapsed column. Hiding a control is not enough: it keeps
    ; its coordinates, which are then the SAME rect as the column that took over its slot (a
    ; collapsed Codex leaves "D:100%"/"W:0%" sitting exactly under Claude's live rows). The
    ; parent has no WS_CLIPCHILDREN and the statics no WS_CLIPSIBLINGS, so any show/hide or
    ; move of a stacked control erases the parent under the visible cell with no guarantee the
    ; cell repaints - and the change gate then keeps the damaged cell until its number moves.
    ; Gui Show AutoSize measures visible controls only, so parking costs no layout.
    parkX := -1000

    codexEligible := showCodex
    claudeEligible := showClaude
    grokEligible := showGrok
    showCodex := (usageMonitorMiniCodexMode = "on")
        || ((usageMonitorMiniCodexMode = "auto" || usageMonitorMiniCodexMode = "free") && codexEligible)
    showClaude := (usageMonitorMiniClaudeMode = "on")
        || ((usageMonitorMiniClaudeMode = "auto" || usageMonitorMiniClaudeMode = "free") && claudeEligible)
        || (usageMonitorMiniClaudeMode = "free" && claudeNoSubscription)
    showGrok := (usageMonitorMiniGrokMode = "on")
        || ((usageMonitorMiniGrokMode = "auto" || usageMonitorMiniGrokMode = "free") && grokEligible)
        || (usageMonitorMiniGrokMode = "free" && grokNoSubscription)
    addonEligible := showAddon
    showAddon := (usageMonitorMiniAddonMode = "on")
        || ((usageMonitorMiniAddonMode = "auto" || usageMonitorMiniAddonMode = "free") && addonEligible)
        || (usageMonitorMiniAddonMode = "free" && addonNoSubscription)
    ; Switched off in Settings: out of the mini view whatever its mini mode (even On).
    if (usageMonitorOffCodex)
        showCodex := false
    if (usageMonitorOffClaude)
        showClaude := false
    if (usageMonitorOffGrok)
        showGrok := false
    ; No add-on module in this host: the column was never built, whatever its mini mode says.
    if (usageMonitorOffAddon || !usageMonitorAddonActive)
        showAddon := false

    ; Forced-on providers without usable quota data remain informative instead of showing
    ; fabricated percentages. An explicit no-subscription state is labeled as (Free).
    ; These MUST go through UsageMonitorSetCtrlText, not a raw GuiControl: the gate is a
    ; write-through cache with no read-back, so a bare write leaves usageMonitorLastCtrlText
    ; describing text that is no longer on screen. The next tick whose computed line happens
    ; to equal that stale cache entry is then skipped, and the notice stays up for good.
    if (showCodex && !codexEligible)
    {
        showCodexDaily := true, showCodexWeekly := false
        UsageMonitorSetCtrlText("UsageMonCodexDaily", "n/a")
    }
    if (showClaude && !claudeEligible)
    {
        showClaudeDaily := true, showClaudeWeekly := false, showClaudeFable := false
        claudeNotice := claudeNoSubscription ? "(Free)" : "n/a"
        UsageMonitorSetCtrlText("UsageMonClaudeDaily", claudeNotice)
    }
    if (showGrok && !grokEligible)
    {
        showGrokMonthly := true
        grokNotice := grokNoSubscription ? "(Free)" : "n/a"
        UsageMonitorSetCtrlText("UsageMonGrokMonthly", grokNotice)
    }
    if (showAddon && !addonEligible)
    {
        showAddonLine1 := true, showAddonLine2 := false
        addonNotice := addonNoSubscription ? "(Free)" : "n/a"
        UsageMonitorSetCtrlText("UsageMonAddonLine1", addonNotice)
    }

    ; Publish what this pass decided so the [T] resets panel can mirror it.
    ; Published AFTER the forced-on adjustments above, which can switch a line off
    ; (a provider with no usable quota shows one "n/a" line, not two).
    usageMonitorMiniShownCodex := showCodex
    usageMonitorMiniShownClaude := showClaude
    usageMonitorMiniShownGrok := showGrok
    ; A provider being on screen does not mean both its lines are. Codex commonly
    ; renders weekly only, with the weekly promoted into the daily row - listing a
    ; "Codex D" reset for a line the user cannot see is the same defect as listing
    ; a hidden provider, one level down.
    usageMonitorMiniShownCodexDaily := (showCodex && showCodexDaily)
    usageMonitorMiniShownCodexWeekly := (showCodex && showCodexWeekly)
    usageMonitorMiniShownClaudeDaily := (showClaude && showClaudeDaily)
    usageMonitorMiniShownClaudeWeekly := (showClaude && showClaudeWeekly)
    usageMonitorMiniShownClaudeFable := (showClaude && showClaudeFable)
    usageMonitorMiniShownGrokWeekly := (showGrok && showGrokMonthly)
    usageMonitorMiniShownAddon := showAddon
    usageMonitorMiniShownAddonLine1 := (showAddon && showAddonLine1)
    usageMonitorMiniShownAddonLine2 := (showAddon && showAddonLine2)

    ; Assign left-to-right slot indices to the visible providers so hidden ones (No
    ; Subscription) collapse the row instead of leaving a gap.
    slot := 0
    codexSlot := -1, claudeSlot := -1, grokSlot := -1, addonSlot := -1
    if (showCodex)
        codexSlot := slot, slot += 1
    if (showClaude)
        claudeSlot := slot, slot += 1
    if (showGrok)
        grokSlot := slot, slot += 1
    if (showAddon)
        addonSlot := slot, slot += 1
    nVisible := slot
    ; An all-hidden state is intentional; AutoSize leaves only the + restore control.

    ; Codex column (header + Daily + Weekly)
    if (codexSlot >= 0)
    {
        cx := leftX + codexSlot * stride
        GuiControl, UsageMon:Move, UsageMonCodexHeader, % "x" . cx
        GuiControl, UsageMon:Show, UsageMonCodexHeader
        if (showCodexDaily)
        {
            GuiControl, UsageMon:Move, UsageMonCodexDaily, % "x" . cx . " y" . yDaily
            GuiControl, UsageMon:Show, UsageMonCodexDaily
        }
        else
            GuiControl, UsageMon:Hide, UsageMonCodexDaily
        if (showCodexWeekly)
        {
            cy := showCodexDaily ? yWeekly : yDaily
            GuiControl, UsageMon:Move, UsageMonCodexWeekly, % "x" . cx . " y" . cy
            GuiControl, UsageMon:Show, UsageMonCodexWeekly
        }
        else
            GuiControl, UsageMon:Hide, UsageMonCodexWeekly
        GuiControl, UsageMon:Move, UsageMonMiniHideCodex, % "x" . cx . " y" . yHead
    }
    else
    {
        GuiControl, UsageMon:Hide, UsageMonCodexHeader
        GuiControl, UsageMon:Hide, UsageMonCodexDaily
        GuiControl, UsageMon:Hide, UsageMonCodexWeekly
        GuiControl, UsageMon:Move, UsageMonCodexHeader, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonCodexDaily, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonCodexWeekly, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonMiniHideCodex, % "x" . parkX . " y" . yHead
    }

    ; Claude column (header + Daily + Weekly)
    if (claudeSlot >= 0)
    {
        cx := leftX + claudeSlot * stride
        GuiControl, UsageMon:Move, UsageMonClaudeHeader, % "x" . cx
        GuiControl, UsageMon:Show, UsageMonClaudeHeader
        ; Rows promote upward: each shown line takes the next free row (D, then W, then the
        ; per-model F line), so a hidden line never leaves a blank row in the column.
        rowY := yDaily
        if (showClaudeDaily)
        {
            GuiControl, UsageMon:Move, UsageMonClaudeDaily, % "x" . cx . " y" . rowY
            GuiControl, UsageMon:Show, UsageMonClaudeDaily
            rowY += lineH
        }
        else
            GuiControl, UsageMon:Hide, UsageMonClaudeDaily
        if (showClaudeWeekly)
        {
            GuiControl, UsageMon:Move, UsageMonClaudeWeekly, % "x" . cx . " y" . rowY
            GuiControl, UsageMon:Show, UsageMonClaudeWeekly
            rowY += lineH
        }
        else
            GuiControl, UsageMon:Hide, UsageMonClaudeWeekly
        if (showClaudeFable)
        {
            GuiControl, UsageMon:Move, UsageMonClaudeFable, % "x" . cx . " y" . rowY
            GuiControl, UsageMon:Show, UsageMonClaudeFable
        }
        else
            GuiControl, UsageMon:Hide, UsageMonClaudeFable
        GuiControl, UsageMon:Move, UsageMonMiniHideClaude, % "x" . cx . " y" . yHead
    }
    else
    {
        GuiControl, UsageMon:Hide, UsageMonClaudeHeader
        GuiControl, UsageMon:Hide, UsageMonClaudeDaily
        GuiControl, UsageMon:Hide, UsageMonClaudeWeekly
        GuiControl, UsageMon:Hide, UsageMonClaudeFable
        GuiControl, UsageMon:Move, UsageMonClaudeHeader, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonClaudeDaily, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonClaudeWeekly, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonClaudeFable, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonMiniHideClaude, % "x" . parkX . " y" . yHead
    }

    ; Grok column (header + single Weekly line on the first metric row)
    if (grokSlot >= 0)
    {
        cx := leftX + grokSlot * stride
        GuiControl, UsageMon:Move, UsageMonGrokHeader, % "x" . cx
        GuiControl, UsageMon:Show, UsageMonGrokHeader
        if (showGrokMonthly)
        {
            GuiControl, UsageMon:Move, UsageMonGrokMonthly, % "x" . cx . " y" . yDaily
            GuiControl, UsageMon:Show, UsageMonGrokMonthly
        }
        else
            GuiControl, UsageMon:Hide, UsageMonGrokMonthly
        GuiControl, UsageMon:Move, UsageMonMiniHideGrok, % "x" . cx . " y" . yHead
    }
    else
    {
        GuiControl, UsageMon:Hide, UsageMonGrokHeader
        GuiControl, UsageMon:Hide, UsageMonGrokMonthly
        GuiControl, UsageMon:Move, UsageMonGrokHeader, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonGrokMonthly, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonMiniHideGrok, % "x" . parkX . " y" . yHead
    }

    ; Add-on column (header + its two rows, promoting upward like Claude); only when built.
    if (usageMonitorAddonActive && addonSlot >= 0)
    {
        cx := leftX + addonSlot * stride
        GuiControl, UsageMon:Move, UsageMonAddonHeader, % "x" . cx
        GuiControl, UsageMon:Show, UsageMonAddonHeader
        rowY := yDaily
        if (showAddonLine1)
        {
            GuiControl, UsageMon:Move, UsageMonAddonLine1, % "x" . cx . " y" . rowY
            GuiControl, UsageMon:Show, UsageMonAddonLine1
            rowY += lineH
        }
        else
            GuiControl, UsageMon:Hide, UsageMonAddonLine1
        if (showAddonLine2)
        {
            GuiControl, UsageMon:Move, UsageMonAddonLine2, % "x" . cx . " y" . rowY
            GuiControl, UsageMon:Show, UsageMonAddonLine2
        }
        else
            GuiControl, UsageMon:Hide, UsageMonAddonLine2
        GuiControl, UsageMon:Move, UsageMonMiniHideAddon, % "x" . cx . " y" . yHead
    }
    else if (usageMonitorAddonActive)
    {
        GuiControl, UsageMon:Hide, UsageMonAddonHeader
        GuiControl, UsageMon:Hide, UsageMonAddonLine1
        GuiControl, UsageMon:Hide, UsageMonAddonLine2
        GuiControl, UsageMon:Move, UsageMonAddonHeader, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonAddonLine1, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonAddonLine2, % "x" . parkX
        GuiControl, UsageMon:Move, UsageMonMiniHideAddon, % "x" . parkX . " y" . yHead
    }

    GuiControl, UsageMon:Hide, UsageMonMiniHideCodex
    GuiControl, UsageMon:Hide, UsageMonMiniHideClaude
    GuiControl, UsageMon:Hide, UsageMonMiniHideGrok
    if (usageMonitorAddonActive)
        GuiControl, UsageMon:Hide, UsageMonMiniHideAddon
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndMiniHideCodex)
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndMiniHideClaude)
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndMiniHideGrok)
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndMiniHideAddon)

    maxMetricRows := 0
    if (showCodex)
        maxMetricRows := Max(maxMetricRows, (showCodexDaily ? 1 : 0) + (showCodexWeekly ? 1 : 0))
    if (showClaude)
        maxMetricRows := Max(maxMetricRows, (showClaudeDaily ? 1 : 0) + (showClaudeWeekly ? 1 : 0) + (showClaudeFable ? 1 : 0))
    if (showGrok)
        maxMetricRows := Max(maxMetricRows, showGrokMonthly ? 1 : 0)
    if (showAddon)
        maxMetricRows := Max(maxMetricRows, (showAddonLine1 ? 1 : 0) + (showAddonLine2 ? 1 : 0))
    dividerH := lineH * (1 + maxMetricRows)

    ; Dividers occupy the gaps after slots 0, 1 and 2 when those gaps exist.
    if (nVisible >= 2)
    {
        GuiControl, UsageMon:Move, UsageMonMiniDivider, % "x" . (leftX + colW + UsScale(5)) . " y" . yHead . " h" . dividerH
        GuiControl, UsageMon:Show, UsageMonMiniDivider
    }
    else
        GuiControl, UsageMon:Hide, UsageMonMiniDivider
    if (nVisible >= 3)
    {
        GuiControl, UsageMon:Move, UsageMonMiniDivider2, % "x" . (leftX + stride + colW + UsScale(5)) . " y" . yHead . " h" . dividerH
        GuiControl, UsageMon:Show, UsageMonMiniDivider2
    }
    else
        GuiControl, UsageMon:Hide, UsageMonMiniDivider2
    if (nVisible >= 4)
    {
        GuiControl, UsageMon:Move, UsageMonMiniDivider3, % "x" . (leftX + 2 * stride + colW + UsScale(5)) . " y" . yHead . " h" . dividerH
        GuiControl, UsageMon:Show, UsageMonMiniDivider3
    }
    else
        GuiControl, UsageMon:Hide, UsageMonMiniDivider3

    ; Right cluster (+ toggle on top, account signal stacked beneath) sits just past the last
    ; visible column. When the signal is hidden it collapses to a clickable dot.
    signalW := usageMonitorShowClaudeAccountMini ? UsScale(34) : UsScale(12)
    clusterX := nVisible ? (leftX + (nVisible - 1) * stride + colW - UsScale(1)) : leftX
    signalVisible := (showClaude && usageMonitorClaudeAccountShort != "")
    usageMonitorMiniSignalActive := signalVisible
    if (signalVisible)
    {
        GuiControl, UsageMon:Move, UsageMonClaudeAccountSignal, % "x" . clusterX . " y" . yDaily . " w" . signalW . " h" . lineH
        ; The full account code (j42@) is always shown; the collapsed dot (·) is a hover-only
        ; peek, so show it now only if the cursor is currently over the HUD.
        dotMode := !usageMonitorShowClaudeAccountMini
        showSignalNow := dotMode ? UsageMonitorCursorOverWindow() : true
        GuiControl, % "UsageMon:" . (showSignalNow ? "Show" : "Hide"), UsageMonClaudeAccountSignal
        usageMonitorMiniDotShown := (dotMode ? showSignalNow : false)
        UsageMonitorRefreshButtonBaseRect(usageMonitorHwndClaudeAccountSignal)
    }
    else
    {
        GuiControl, UsageMon:Hide, UsageMonClaudeAccountSignal
        usageMonitorMiniDotShown := false
    }

    ; Reposition the toggle with x/y ONLY (no w/h): its size is constant (set at build), and a
    ; resize here would re-trigger the static's paint and can drop the SS_CENTERIMAGE vertical
    ; centering, leaving the "+" looking off-center after the first data refresh.
    GuiControl, UsageMon:Move, UsageMonViewToggleBtn, % "x" . clusterX . " y" . yHead
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndViewToggleBtn)
    if (usageMonitorVisible && UsageMonitorWindowIsVisible())
    {
        Gui, UsageMon:Show, AutoSize NoActivate
        UsageMonitorApplyAnchor()
    }
    ; The Move + AutoSize relayout above can leave the toggle static painted top-aligned
    ; (reproducible the moment the account signal becomes visible) — its SS_CENTER/SS_CENTERIMAGE
    ; bits get dropped. Re-assert the style bits directly and force a frame-changed repaint so
    ; the glyph stays centered in its border regardless of which controls just changed.
    UsageMonitorReassertToggleCentering()
}

; Force SS_CENTER + SS_CENTERIMAGE back onto the view-toggle static and repaint. Static text
; centering can be lost across runtime Move/AutoSize relayouts; restoring the GWL_STYLE bits
; (not just re-painting) is what actually re-centers the +/- glyph.
UsageMonitorReassertToggleCentering()
{
    global usageMonitorHwndViewToggleBtn
    hwnd := usageMonitorHwndViewToggleBtn
    if (!hwnd)
        return
    getFn := (A_PtrSize = 8) ? "GetWindowLongPtr" : "GetWindowLong"
    setFn := (A_PtrSize = 8) ? "SetWindowLongPtr" : "SetWindowLong"
    style := DllCall(getFn, "Ptr", hwnd, "Int", -16, "Ptr")            ; GWL_STYLE
    newStyle := (style & ~0x1F) | 0x1 | 0x200                          ; SS_CENTER | SS_CENTERIMAGE
    if (newStyle != style)
        DllCall(setFn, "Ptr", hwnd, "Int", -16, "Ptr", newStyle)
    ; SWP_NOSIZE|NOMOVE|NOZORDER|FRAMECHANGED so the static recomputes its text rect, then paint.
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0027)
    DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", true)
}

UsageMonitorWindowIsVisible()
{
    global usageMonitorHwnd

    if (!usageMonitorHwnd)
        return false
    return DllCall("IsWindowVisible", "Ptr", usageMonitorHwnd)
}

UsageMonitorReadStatus(path)
{
    local statusRaw, statusText

    if (path = "" || !FileExist(path))
        return ""

    FileRead, statusRaw, %path%
    if (ErrorLevel)
        return ""

    statusText := Trim(statusRaw, " `t`r`n")
    return statusText
}

UsageMonitorReadSnapshot(path)
{
    local snapshot, raw, line, delimPos, key, value

    snapshot := {}
    snapshot["fetched_at_local"] := ""
    snapshot["fetched_at_utc"] := ""
    snapshot["overall_status"] := "error"
    snapshot["codex_status"] := "error"
    snapshot["codex_line_1"] := "Daily: unavailable"
    snapshot["codex_line_2"] := "Weekly: unavailable"
    snapshot["claude_status"] := "error"
    snapshot["claude_account_label"] := ""
    snapshot["claude_profile"] := ""
    snapshot["claude_profile_choices"] := ""
    snapshot["claude_next_profile"] := ""
    snapshot["claude_profile_switch_available"] := "0"
    snapshot["claude_line_1"] := "Daily: unavailable"
    snapshot["claude_line_2"] := "Weekly: unavailable"
    snapshot["error"] := ""

    if (path = "" || !FileExist(path))
    {
        snapshot["error"] := "No data received."
        return snapshot
    }

    FileRead, raw, %path%
    if (ErrorLevel)
    {
        snapshot["error"] := "Could not read output."
        return snapshot
    }

    Loop, Parse, raw, `n, `r
    {
        line := A_LoopField
        if (line = "")
            continue
        delimPos := InStr(line, "=")
        if (delimPos <= 0)
            continue
        key := SubStr(line, 1, delimPos - 1)
        value := SubStr(line, delimPos + 1)
        snapshot[key] := value
    }

    return snapshot
}

UsageMonitorIsUnavailableLine(value)
{
    local trimmedValue, lowerValue

    trimmedValue := Trim(value, " `t`r`n")
    if (trimmedValue = "")
        return true

    StringLower, lowerValue, trimmedValue
    if (InStr(lowerValue, "unavailable"))
        return true

    return false
}

UsageMonitorSetState(stateText)
{
    global usageMonitorCtrlColors, usageMonitorViewMode
    global usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndGrokMonthly
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar
    global usageMonitorHwndClaudeFable, usageMonitorHwndClaudeFableBar
    global usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar
    global usageMonitorLastBarState

    if (stateText = "Refreshing...")
    {
        usageMonitorCtrlColors[usageMonitorHwndCodexDaily]   := UsageMonitorThemeRef("dimmer")
        usageMonitorCtrlColors[usageMonitorHwndCodexWeekly]  := UsageMonitorThemeRef("dimmer")
        usageMonitorCtrlColors[usageMonitorHwndClaudeDaily]  := UsageMonitorThemeRef("dimmer")
        usageMonitorCtrlColors[usageMonitorHwndClaudeWeekly] := UsageMonitorThemeRef("dimmer")
        if (usageMonitorHwndClaudeFable)
            usageMonitorCtrlColors[usageMonitorHwndClaudeFable] := UsageMonitorThemeRef("dimmer")
        usageMonitorCtrlColors[usageMonitorHwndGrokMonthly]  := UsageMonitorThemeRef("dimmer")
        if (usageMonitorHwndAddonLine1)
            usageMonitorCtrlColors[usageMonitorHwndAddonLine1] := UsageMonitorThemeRef("dimmer")
        if (usageMonitorHwndAddonLine2)
            usageMonitorCtrlColors[usageMonitorHwndAddonLine2] := UsageMonitorThemeRef("dimmer")
        if (usageMonitorViewMode = "mini")
        {
            UsageMonitorSetCtrlText("UsageMonCodexDaily",   "D: ...")
            UsageMonitorSetCtrlText("UsageMonCodexWeekly",  "W: ...")
            UsageMonitorSetCtrlText("UsageMonClaudeDaily",  "D: ...")
            UsageMonitorSetCtrlText("UsageMonClaudeWeekly", "W: ...")
            if (usageMonitorHwndClaudeFable)
                UsageMonitorSetCtrlText("UsageMonClaudeFable", "F: ...")
            UsageMonitorSetCtrlText("UsageMonGrokMonthly",  "W: ...")
            if (usageMonitorHwndAddonLine1)
                UsageMonitorSetCtrlText("UsageMonAddonLine1", "...")
            if (usageMonitorHwndAddonLine2)
                UsageMonitorSetCtrlText("UsageMonAddonLine2", "...")
        }
        else
        {
            UsageMonitorSetCtrlText("UsageMonCodexDaily",   "Refreshing...")
            UsageMonitorSetCtrlText("UsageMonCodexWeekly",  "Refreshing...")
            UsageMonitorSetCtrlText("UsageMonClaudeDaily",  "Refreshing...")
            UsageMonitorSetCtrlText("UsageMonClaudeWeekly", "Refreshing...")
            if (usageMonitorHwndClaudeFable)
                UsageMonitorSetCtrlText("UsageMonClaudeFable", "Refreshing...")
            UsageMonitorSetCtrlText("UsageMonGrokMonthly",  "Refreshing...")
            if (usageMonitorHwndAddonLine1)
                UsageMonitorSetCtrlText("UsageMonAddonLine1", "Refreshing...")
            if (usageMonitorHwndAddonLine2)
                UsageMonitorSetCtrlText("UsageMonAddonLine2", "Refreshing...")
        }
        if (usageMonitorHwndCodexDailyBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndCodexDailyBar%
        if (usageMonitorHwndCodexWeeklyBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndCodexWeeklyBar%
        if (usageMonitorHwndClaudeDailyBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndClaudeDailyBar%
        if (usageMonitorHwndClaudeWeeklyBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndClaudeWeeklyBar%
        if (usageMonitorHwndClaudeFableBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndClaudeFableBar%
        if (usageMonitorHwndGrokMonthlyBar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndGrokMonthlyBar%
        if (usageMonitorHwndAddonLine1Bar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndAddonLine1Bar%
        if (usageMonitorHwndAddonLine2Bar)
            SendMessage, 0x402, 0, 0,, ahk_id %usageMonitorHwndAddonLine2Bar%
        ; The bars were just driven to 0 behind UsageMonitorUpdateBar's back, so drop its
        ; cache - otherwise the snapshot that lands next would see "already at that value"
        ; and leave every bar sitting empty.
        usageMonitorLastBarState := {}
        UsageMonitorRepaintThemedStatics()
    }
}

; Grok row/header links use the same provider URL opener as the always-clickable headers.
UsageMonitorOpenGrokPage()
{
    return UsageMonitorRunProviderUrl("https://grok.com/?_s=usage")
}

; The add-on header opens the module's own link (addon_link), and only a plain https URL: it
; reaches Run below, which would start a program for anything that is not a URL.
UsageMonitorOpenAddonPage()
{
    global usageMonitorAddonActive, usageMonitorAddonLink
    if (!usageMonitorAddonActive || !UsageMonitorAddonLinkIsSafe(usageMonitorAddonLink))
        return false
    return UsageMonitorRunProviderUrl(usageMonitorAddonLink)
}

; Open provider usage pages in Firefox - the browser whose plaintext cookies.sqlite the
; scraper reads. Normal launches use Firefox's true registered default profile. Claude may
; request Firefox's profile manager so the user chooses an account before the page opens.
; Every path falls back to default URL handling if Firefox cannot be launched.
UsageMonitorRunProviderUrl(url, promptForProfile := false)
{
    local runTarget

    if (promptForProfile)
    {
        runTarget := "firefox.exe -no-remote -ProfileManager """ . url . """"
        Run, %runTarget%,, UseErrorLevel
        if (ErrorLevel != "ERROR")
            return true
    }

    runTarget := "firefox.exe """ . url . """"
    Run, %runTarget%,, UseErrorLevel
    if (ErrorLevel != "ERROR")
        return true

    Run, %url%,, UseErrorLevel
    return (ErrorLevel != "ERROR")
}

UsageMonitorOpenCodexPage()
{
    return UsageMonitorRunProviderUrl("https://chatgpt.com/codex/settings/usage")
}

UsageMonitorOpenClaudePage()
{
    return UsageMonitorRunProviderUrl("https://claude.ai/settings/usage", true)
}

UsageMonitorProviderNeedsAttention(providerStatus, line1, line2 := "")
{
    if (providerStatus = "error" || providerStatus = "login_required")
        return true
    return UsageMonitorIsUnavailableLine(line1) || (line2 != "" && UsageMonitorIsUnavailableLine(line2))
}

UsageMonitorProviderErrorSegment(label, errorText)
{
    local startAt, segment, separatorAt

    startAt := InStr(errorText, label)
    if (!startAt)
        return ""

    segment := SubStr(errorText, startAt)
    separatorAt := InStr(segment, " | ")
    if (separatorAt)
        segment := SubStr(segment, 1, separatorAt - 1)
    return Trim(segment, " `t`r`n")
}

UsageMonitorCompactProviderError(label, providerStatus, line1, line2, errorText)
{
    local providerError, lowerError

    if (!UsageMonitorProviderNeedsAttention(providerStatus, line1, line2))
        return ""

    if (providerStatus = "login_required")
        return label . " sign-in required"

    providerError := UsageMonitorProviderErrorSegment(label, errorText)
    if (providerError = "")
        return label . " unavailable"
    StringLower, lowerError, providerError

    if (InStr(lowerError, "could not determine api url"))
        return label . " API URL unavailable"
    if (InStr(lowerError, "session token failed") && InStr(lowerError, "aborted"))
        return label . " session aborted"
    if (InStr(lowerError, "fetch failed"))
        return label . " fetch failed"
    if (InStr(lowerError, "request timed out"))
        return label . " timed out"
    if (InStr(lowerError, "could not parse") || InStr(lowerError, "credits payload"))
        return label . " parse failed"
    if (InStr(lowerError, "http "))
        return label . " API error"
    if (InStr(lowerError, "snapshot failed"))
        return label . " snapshot failed"

    return label . " unavailable"
}

UsageMonitorAppendCompactPart(ByRef summary, part)
{
    if (part = "")
        return
    if (summary != "")
        summary := summary . "; "
    summary := summary . part
}

UsageMonitorLoginProviderNames(snapshot)
{
    local codexLogin, claudeLogin

    codexLogin := (UsageMonitorValue(snapshot, "codex_status", "") = "login_required")
    claudeLogin := (UsageMonitorValue(snapshot, "claude_status", "") = "login_required")
    if (codexLogin && claudeLogin)
        return "Codex and Claude"
    if (codexLogin)
        return "Codex"
    if (claudeLogin)
        return "Claude"
    return ""
}

; How to sign in again, following each provider's Settings source: a CLI-only provider needs its
; CLI run, a Firefox-only one a browser sign-in, auto takes either.
; "Run codex or open Codex above" / "Run claude" / "Open Codex and Claude above".
UsageMonitorLoginActionText(snapshot)
{
    local cmds, opens, index, provider, pref

    cmds := "", opens := ""
    for index, provider in ["codex", "claude"]
    {
        if (UsageMonitorValue(snapshot, provider . "_status", "") != "login_required")
            continue
        pref := UsageMonitorProviderPref(provider)
        if (pref != "firefox")
            cmds := cmds . (cmds = "" ? "" : " and ") . provider
        if (pref != "cli")
            opens := opens . (opens = "" ? "" : " and ") . UsageMonitorProviderDisplayName(provider)
    }
    if (cmds != "" && opens != "")
        return "Run " . cmds . " or open " . opens . " above"
    if (cmds != "")
        return "Run " . cmds
    if (opens != "")
        return "Open " . opens . " above"
    return "Open the affected provider above"
}

UsageMonitorCompactErrorForDisplay(snapshot, status, errorText)
{
    local summary, part, prefix, compact, partCount, loginProviders, providerWord

    errorText := Trim(errorText, " `t`r`n")
    if (errorText = "" || !IsObject(snapshot))
        return errorText

    summary := ""
    partCount := 0
    part := UsageMonitorCompactProviderError("Codex"
        , UsageMonitorValue(snapshot, "codex_status", "")
        , UsageMonitorValue(snapshot, "codex_line_1", "")
        , UsageMonitorValue(snapshot, "codex_line_2", "")
        , errorText)
    UsageMonitorAppendCompactPart(summary, part)
    if (part != "")
        partCount++

    part := UsageMonitorCompactProviderError("Claude"
        , UsageMonitorValue(snapshot, "claude_status", "")
        , UsageMonitorValue(snapshot, "claude_line_1", "")
        , UsageMonitorValue(snapshot, "claude_line_2", "")
        , errorText)
    UsageMonitorAppendCompactPart(summary, part)
    if (part != "")
        partCount++

    part := UsageMonitorCompactProviderError("Grok"
        , UsageMonitorValue(snapshot, "grok_status", "")
        , UsageMonitorValue(snapshot, "grok_line_1", "")
        , UsageMonitorValue(snapshot, "grok_line_2", "")
        , errorText)
    UsageMonitorAppendCompactPart(summary, part)
    if (part != "")
        partCount++

    if (usageMonitorAddonActive)
    {
        part := UsageMonitorCompactProviderError(UsageMonitorAddonDisplayLabel()
            , UsageMonitorValue(snapshot, "addon_status", "")
            , UsageMonitorValue(snapshot, "addon_line_1", "")
            , UsageMonitorValue(snapshot, "addon_line_2", "")
            , errorText)
        UsageMonitorAppendCompactPart(summary, part)
        if (part != "")
            partCount++
    }

    if (summary = "")
        return UsageMonitorTruncateText(errorText, 126)
    ; An add-on signs in its own way (its module's hint), not through a web page, so
    ; "Open ... above" would mislead.
    if (usageMonitorAddonActive && partCount = 1 && usageMonitorAddonHint != ""
        && summary = UsageMonitorAddonDisplayLabel() . " sign-in required")
        return usageMonitorAddonHint

    loginProviders := UsageMonitorLoginProviderNames(snapshot)
    if (loginProviders != "")
        compact := summary . ". " . UsageMonitorLoginActionText(snapshot) . ", then Refresh."
    else
    {
        prefix := (status = "login_required") ? "" : "Unavailable: "
        providerWord := (partCount = 1) ? "provider" : "providers"
        compact := prefix . summary . ". Open affected " . providerWord . " above, then Refresh."
    }
    return UsageMonitorTruncateText(compact, 150)
}

; Returns true when the message actually changed. Unchanged text means the height and
; the footer reflow are unchanged too, so the whole resize path is skipped - a steady
; refresh must not re-AutoSize the window. A rebuild clears the text cache, so the first
; call after one always takes the full path.
UsageMonitorSetError(errorText)
{
    global usageMonitorViewMode

    if (!UsageMonitorSetCtrlText("UsageMonError", errorText))
        return false

    ; Mini view: the error control is a hidden 1px stub — never grows the tiny HUD.
    if (usageMonitorViewMode != "full")
    {
        GuiControl, UsageMon:Move, UsageMonError, % "h" . UsScale(1)
        return true
    }

    ; Size the single actionable message to fit its text and push the footer
    ; down so the red message is fully visible instead of clipped/overlapping the hint text.
    errH := (errorText = "") ? UsScale(1) : UsageMonitorErrorHeightFor(errorText)
    GuiControl, UsageMon:Move, UsageMonError, % "h" . errH
    UsageMonitorReflowErrorFooter(errH - UsScale(1))
    return true
}

; Estimate the wrapped height of an error message at the full error-control width (~280px,
; ~42 chars/line at font s8). Clamped to 1-3 lines so a long install hint stays bounded.
UsageMonitorErrorHeightFor(errorText)
{
    local lines
    lines := Ceil(StrLen(errorText) / 42)
    if (lines < 1)
        lines := 1
    else if (lines > 3)
        lines := 3
    return UsScale(lines * 14 + 2)
}

; Push the full-view footer (help + Refresh/Resets) down by "delta" px from its collapsed
; baseline (the extra height of the single error/status row) and re-autosize the window. No-op
; when the delta is already applied (steady-state refreshes don't flicker). Button
; hit-zones are refreshed after moving.
UsageMonitorReflowErrorFooter(delta)
{
    global usageMonitorErrorShownHeight, usageMonitorVisible, usageMonitorHwnd
    global usageMonitorFooterBaseYHelp, usageMonitorFooterBaseYRefresh, usageMonitorFooterBaseYResets
    global usageMonitorHwndRefreshBtn, usageMonitorHwndResetToggleBtn

    if (delta = usageMonitorErrorShownHeight)
        return
    usageMonitorErrorShownHeight := delta
    GuiControl, UsageMon:Move, UsageMonHelp,           % "y" . (usageMonitorFooterBaseYHelp + delta)
    GuiControl, UsageMon:Move, UsageMonRefreshBtn,     % "y" . (usageMonitorFooterBaseYRefresh + delta)
    GuiControl, UsageMon:Move, UsageMonResetToggleBtn, % "y" . (usageMonitorFooterBaseYResets + delta)
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndRefreshBtn)
    UsageMonitorRefreshButtonBaseRect(usageMonitorHwndResetToggleBtn)

    if (usageMonitorVisible && usageMonitorHwnd)
    {
        Gui, UsageMon:Show, AutoSize NoActivate
        UsageMonitorPositionSprite()
        UsageMonitorApplyAnchor()
    }
}

; One add-on row with its value replaced: "Pro: 70% remaining" -> "Pro: Off". A row without a
; label becomes the word alone, and an empty row stays empty (an add-on may use one row).
UsageMonitorAddonRewriteLine(lineText, word)
{
    local labelMatch, labelMatch1

    if (Trim(lineText) = "")
        return ""
    if (RegExMatch(lineText, "^\s*([A-Za-z0-9][A-Za-z0-9 ._+-]{0,5}):", labelMatch))
        return labelMatch1 . ": " . word
    return word
}

; Takes the add-on's label, link, sign-in hint and Settings warning from a snapshot. They are
; display text only; the link is opened only after UsageMonitorAddonLinkIsSafe. A new label is
; written to the headers and kept in [State] addonLabel. Returns true when the header changed.
UsageMonitorApplyAddonMeta(snapshot)
{
    global usageMonitorAddonLabel, usageMonitorAddonLink, usageMonitorAddonHint, usageMonitorAddonWarning
    global usageMonitorStatePath, usageMonitorHwndAddonHeader

    addonMetaChanged := false
    addonNewLabel := UsageMonitorValue(snapshot, "addon_label", "")
    if (UsageMonitorAddonLabelIsValid(addonNewLabel) && addonNewLabel !== usageMonitorAddonLabel)
    {
        usageMonitorAddonLabel := addonNewLabel
        IniWrite, %addonNewLabel%, %usageMonitorStatePath%, State, addonLabel
        if (usageMonitorHwndAddonHeader)
            addonMetaChanged := UsageMonitorSetCtrlText("UsageMonAddonHeader", addonNewLabel)
    }
    if (UsageMonitorValue(snapshot, "addon_status", "") != "off")
    {
        usageMonitorAddonLink := UsageMonitorValue(snapshot, "addon_link", "")
        usageMonitorAddonHint := SubStr(UsageMonitorValue(snapshot, "addon_hint", ""), 1, 120)
        usageMonitorAddonWarning := SubStr(UsageMonitorValue(snapshot, "addon_warning", ""), 1, 120)
    }
    return addonMetaChanged
}

UsageMonitorApplySnapshot(snapshot, status)
{
    global usageMonitorCtrlColors, usageMonitorShowResetDates, usageMonitorViewMode
    global usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus
    global usageMonitorHwndCodexDaily, usageMonitorHwndCodexWeekly
    global usageMonitorHwndClaudeDaily, usageMonitorHwndClaudeWeekly
    global usageMonitorHwndCodexDailyBar, usageMonitorHwndCodexWeeklyBar
    global usageMonitorHwndClaudeDailyBar, usageMonitorHwndClaudeWeeklyBar
    global usageMonitorHwndClaudeFable, usageMonitorHwndClaudeFableBar
    global usageMonitorClaudeFableActive, usageMonitorBuiltClaudeFable
    global usageMonitorGuiReady, usageMonitorVisible
    global usageMonitorHwndGrokMonthly, usageMonitorHwndGrokMonthlyBar
    global usageMonitorHwndSprite, usageMonitorHwndSpritePlaceholder
    global usageMonitorClaudeAccountShort, UsageMonClaudeAccountSignal, usageMonitorShowClaudeAccountMini
    global usageMonitorGrokLinkActive
    global usageMonitorMiniCodexEligible, usageMonitorMiniClaudeEligible, usageMonitorMiniGrokEligible
    global usageMonitorMiniCodexMode, usageMonitorMiniClaudeMode, usageMonitorMiniGrokMode
    global usageMonitorMiniAddonEligible, usageMonitorMiniAddonMode
    global usageMonitorHwndAddonLine1, usageMonitorHwndAddonLine2
    global usageMonitorHwndAddonLine1Bar, usageMonitorHwndAddonLine2Bar
    global usageMonitorSnapshotChanged, usageMonitorMiniLayoutKey
    global usageMonitorSpriteApplied, usageMonitorLoginHintCollapsed
    global usageMonitorUiScale, usageMonitorShowResetDates
    global usageMonitorOffCodex, usageMonitorOffClaude, usageMonitorOffGrok, usageMonitorOffAddon
    global usageMonitorAddonActive

    ; Every on-screen mutation below ORs into this. It drives both the "did anything
    ; move" signal the adaptive cadence needs and the decision to skip the final
    ; synchronous repaint entirely on a no-change tick.
    usageMonitorSnapshotChanged := false

    usageMonitorLastSnapshot := snapshot
    usageMonitorLastSnapshotStatus := status
    UsageMonitorUpdateClaudeProfileState(snapshot)

    if (status = "")
        status := UsageMonitorValue(snapshot, "overall_status", "error")

    codexStatus := UsageMonitorValue(snapshot, "codex_status", "")
    claudeStatus := UsageMonitorValue(snapshot, "claude_status", "")
    grokStatus := UsageMonitorValue(snapshot, "grok_status", "")
    codexLine1  := UsageMonitorValue(snapshot, "codex_line_1",  "Daily: unavailable")
    codexLine2  := UsageMonitorValue(snapshot, "codex_line_2",  "Weekly: unavailable")
    claudeLine1 := UsageMonitorValue(snapshot, "claude_line_1", "Daily: unavailable")
    claudeLine2 := UsageMonitorValue(snapshot, "claude_line_2", "Weekly: unavailable")
    grokLine1   := UsageMonitorValue(snapshot, "grok_line_1",   "Weekly: unavailable")
    ; The add-on (only when this host has one): its rows plus its display metadata.
    addonStatus := usageMonitorAddonActive ? UsageMonitorValue(snapshot, "addon_status", "") : "off"
    addonLine1 := usageMonitorAddonActive ? UsageMonitorValue(snapshot, "addon_line_1", UsageMonitorAddonDisplayLabel() . ": unavailable") : ""
    addonLine2 := usageMonitorAddonActive ? UsageMonitorValue(snapshot, "addon_line_2", "") : ""
    if (usageMonitorAddonActive && UsageMonitorApplyAddonMeta(snapshot))
        usageMonitorSnapshotChanged := true

    ; Switched off in Settings (the scraper's "off" status, or turned off since this snapshot was
    ; taken): the full view shows a dim Off row and the mini view leaves the provider out.
    usageMonitorOffCodex := UsageMonitorProviderShownOff("codex", codexStatus)
    usageMonitorOffClaude := UsageMonitorProviderShownOff("claude", claudeStatus)
    usageMonitorOffGrok := UsageMonitorProviderShownOff("grok", grokStatus)
    usageMonitorOffAddon := UsageMonitorProviderShownOff("addon", addonStatus)
    if (usageMonitorOffCodex)
        codexStatus := "off", codexLine1 := "Daily: Off", codexLine2 := "Weekly: Off"
    if (usageMonitorOffClaude)
        claudeStatus := "off", claudeLine1 := "Daily: Off", claudeLine2 := "Weekly: Off"
    if (usageMonitorOffGrok)
        grokStatus := "off", grokLine1 := "Weekly: Off"
    if (usageMonitorOffAddon)
        addonStatus := "off", addonLine1 := UsageMonitorAddonRewriteLine(addonLine1, "Off"), addonLine2 := UsageMonitorAddonRewriteLine(addonLine2, "Off")

    codexFreeUsageVisible := (codexStatus = "free" && usageMonitorMiniCodexMode = "free")
    if (codexStatus = "free" && !codexFreeUsageVisible)
    {
        codexLine1 := "Daily: No Subscription"
        codexLine2 := "Weekly: No Subscription"
    }

    claudeFreeUsageVisible := (claudeStatus = "free" && usageMonitorMiniClaudeMode = "free")
    if (claudeStatus = "free" && !claudeFreeUsageVisible)
    {
        claudeLine1 := "Daily: No Subscription"
        claudeLine2 := "Weekly: No Subscription"
    }

    ; Per-model scoped weekly line (e.g. "Fable: 87% remaining", claude_line_3). Auto-gated:
    ; treated as absent when the snapshot lacks it or the free rewrite hides the real numbers.
    claudeLine3 := UsageMonitorValue(snapshot, "claude_line_3", "")
    if ((claudeStatus = "free" && !claudeFreeUsageVisible) || usageMonitorOffClaude)
        claudeLine3 := ""
    usageMonitorClaudeFableActive := (claudeLine3 != "")

    ; The full view builds the Fable row conditionally, and AHK statics never reflow around a
    ; hidden control — so when the row's presence flips between snapshots, destroy + rebuild
    ; (same path as the theme toggle). The nested ApplySnapshot inside the rebuild sees a
    ; matching layout, so this cannot recurse.
    if (usageMonitorViewMode = "full" && usageMonitorGuiReady && usageMonitorVisible
        && usageMonitorBuiltClaudeFable != usageMonitorClaudeFableActive)
    {
        UsageMonitorRebuildForFableChange()
        return
    }

    ; Grok is single-window, so only the Weekly line is rewritten. The scraper keeps the real
    ; free-tier percentage in the snapshot; Mini: Free is what reveals it (same as the others).
    grokFreeUsageVisible := (grokStatus = "free" && usageMonitorMiniGrokMode = "free")
    if (grokStatus = "free" && !grokFreeUsageVisible)
        grokLine1 := "Weekly: No Subscription"

    ; Add-on free (e.g. a starter quota): real numbers, shown only in Mini: Free.
    addonFreeUsageVisible := (addonStatus = "free" && usageMonitorMiniAddonMode = "free")
    if (addonStatus = "free" && !addonFreeUsageVisible)
    {
        addonLine1 := UsageMonitorAddonRewriteLine(addonLine1, "No Subscription")
        addonLine2 := UsageMonitorAddonRewriteLine(addonLine2, "No Subscription")
    }

    codexDailyHasData := UsageMonitorLineHasPercent(codexLine1)
    codexWeeklyHasData := UsageMonitorLineHasPercent(codexLine2)
    claudeDailyHasData := UsageMonitorLineHasPercent(claudeLine1)
    claudeWeeklyHasData := UsageMonitorLineHasPercent(claudeLine2)
    claudeFableHasData := UsageMonitorLineHasPercent(claudeLine3)
    claudeNoSubscription := UsageMonitorIsNoSubscriptionLine(claudeLine1)
        || UsageMonitorIsNoSubscriptionLine(claudeLine2)
    grokMonthlyHasData := UsageMonitorLineHasPercent(grokLine1)
    grokNoSubscription := UsageMonitorIsNoSubscriptionLine(grokLine1)
    addonLine1HasData := UsageMonitorLineHasPercent(addonLine1)
    addonLine2HasData := UsageMonitorLineHasPercent(addonLine2)
    addonNoSubscription := UsageMonitorIsNoSubscriptionLine(addonLine1)
        || UsageMonitorIsNoSubscriptionLine(addonLine2)
    ; Auto mode collapses a provider once its weekly allowance is exhausted, even if
    ; a shorter daily window still has quota. Forced On continues to show the 0% line.
    usageMonitorMiniCodexEligible := (codexDailyHasData || codexWeeklyHasData)
        && !(codexWeeklyHasData && UsageMonitorLineIsZero(codexLine2))
    usageMonitorMiniClaudeEligible := (claudeDailyHasData || claudeWeeklyHasData)
        && !(claudeWeeklyHasData && UsageMonitorLineIsZero(claudeLine2))
    usageMonitorMiniGrokEligible := grokMonthlyHasData && !UsageMonitorLineIsZero(grokLine1)
    ; The add-on has no weekly/daily split: collapse only once every window it reports is exhausted.
    usageMonitorMiniAddonEligible := (addonLine1HasData || addonLine2HasData)
        && !((!addonLine1HasData || UsageMonitorLineIsZero(addonLine1))
            && (!addonLine2HasData || UsageMonitorLineIsZero(addonLine2)))

    ; Reset suffix shows when the Resets toggle is on, OR always on a 0% line so
    ; the user can see when an exhausted quota comes back regardless of the toggle.
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(codexLine1))
        codexLine1  := UsageMonitorAppendReset(codexLine1,  UsageMonitorValue(snapshot, "codex_line_1_reset_text",  ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(codexLine2))
        codexLine2  := UsageMonitorAppendReset(codexLine2,  UsageMonitorValue(snapshot, "codex_line_2_reset_text",  ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(claudeLine1))
        claudeLine1 := UsageMonitorAppendReset(claudeLine1, UsageMonitorValue(snapshot, "claude_line_1_reset_text", ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(claudeLine2))
        claudeLine2 := UsageMonitorAppendReset(claudeLine2, UsageMonitorValue(snapshot, "claude_line_2_reset_text", ""))
    if (claudeLine3 != "" && (usageMonitorShowResetDates || UsageMonitorLineIsZero(claudeLine3)))
        claudeLine3 := UsageMonitorAppendReset(claudeLine3, UsageMonitorValue(snapshot, "claude_line_3_reset_text", ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(grokLine1))
        grokLine1 := UsageMonitorAppendReset(grokLine1, UsageMonitorValue(snapshot, "grok_line_1_reset_text", ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(addonLine1))
        addonLine1 := UsageMonitorAppendReset(addonLine1, UsageMonitorValue(snapshot, "addon_line_1_reset_text", ""))
    if (usageMonitorShowResetDates || UsageMonitorLineIsZero(addonLine2))
        addonLine2 := UsageMonitorAppendReset(addonLine2, UsageMonitorValue(snapshot, "addon_line_2_reset_text", ""))

    ; Grok failed to fetch (unavailable / could-not-parse / n/a — no percent, and not a
    ; genuine No-Subscription): in FULL view turn the Weekly line into a clickable link that
    ; opens grok.com in Firefox so the user can log in / check. Mini view collapses the Grok
    ; column entirely (UsageMonitorLineHasPercent), so this affordance is full-view only.
    grokLinkActive := (!UsageMonitorLineHasPercent(grokLine1) && !usageMonitorOffGrok
        && !UsageMonitorIsNoSubscriptionLine(grokLine1) && usageMonitorViewMode = "full")
    if (grokLinkActive)
        grokLine1 := grokLine1 . "   " . Chr(0x2192) . " Open Grok"
    usageMonitorGrokLinkActive := grokLinkActive

    errorText := UsageMonitorValue(snapshot, "error", "")

    if (usageMonitorViewMode = "mini")
    {
        codexLine1 := UsageMonitorCompactMetricLine(codexLine1)
        codexLine2 := UsageMonitorCompactMetricLine(codexLine2)
        claudeLine1 := UsageMonitorCompactMetricLine(claudeLine1)
        claudeLine2 := UsageMonitorCompactMetricLine(claudeLine2)
        if (claudeLine3 != "")
            claudeLine3 := UsageMonitorCompactMetricLine(claudeLine3)
        grokLine1 := UsageMonitorCompactMetricLine(grokLine1)
        addonLine1 := UsageMonitorCompactMetricLine(addonLine1)
        addonLine2 := UsageMonitorCompactMetricLine(addonLine2)
    }

    ; Update colors before updating text so repaint uses the new color. Both go through
    ; the change gates: on a tick where the numbers did not move, not one control is
    ; touched and the popup does not repaint at all.
    if (UsageMonitorSetCtrlColor(usageMonitorHwndCodexDaily,   UsageMonitorGetMetricColorRef(codexLine1)))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlColor(usageMonitorHwndCodexWeekly,  UsageMonitorGetMetricColorRef(codexLine2)))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlColor(usageMonitorHwndClaudeDaily,  UsageMonitorGetMetricColorRef(claudeLine1)))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlColor(usageMonitorHwndClaudeWeekly, UsageMonitorGetMetricColorRef(claudeLine2)))
        usageMonitorSnapshotChanged := true
    if (usageMonitorHwndClaudeFable)
    {
        if (UsageMonitorSetCtrlColor(usageMonitorHwndClaudeFable, UsageMonitorGetMetricColorRef(claudeLine3)))
            usageMonitorSnapshotChanged := true
    }
    ; A failed Grok line renders in the theme accent so it reads as a link.
    grokColorRef := grokLinkActive
        ? UsageMonitorThemeRef("header")
        : UsageMonitorGetMetricColorRef(grokLine1)
    if (UsageMonitorSetCtrlColor(usageMonitorHwndGrokMonthly, grokColorRef))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlColor(usageMonitorHwndAddonLine1, UsageMonitorGetMetricColorRef(addonLine1)))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlColor(usageMonitorHwndAddonLine2, UsageMonitorGetMetricColorRef(addonLine2)))
        usageMonitorSnapshotChanged := true

    if (UsageMonitorSetCtrlText("UsageMonCodexDaily", codexLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlText("UsageMonCodexWeekly", codexLine2))
        usageMonitorSnapshotChanged := true
    ; UsageMonitorClaudeHeaderText is currently a constant, so this write is skipped on
    ; every snapshot while still letting a dynamic header text through.
    if (UsageMonitorSetCtrlText("UsageMonClaudeHeader", UsageMonitorClaudeHeaderText(snapshot)))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateClaudeAccountDisplay(snapshot))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateSourceTags(snapshot))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlText("UsageMonClaudeDaily", claudeLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorSetCtrlText("UsageMonClaudeWeekly", claudeLine2))
        usageMonitorSnapshotChanged := true
    if (usageMonitorHwndClaudeFable)
    {
        if (UsageMonitorSetCtrlText("UsageMonClaudeFable", claudeLine3))
            usageMonitorSnapshotChanged := true
    }
    if (UsageMonitorSetCtrlText("UsageMonGrokMonthly", grokLine1))
        usageMonitorSnapshotChanged := true
    if (usageMonitorHwndAddonLine1 && UsageMonitorSetCtrlText("UsageMonAddonLine1", addonLine1))
        usageMonitorSnapshotChanged := true
    if (usageMonitorHwndAddonLine2 && UsageMonitorSetCtrlText("UsageMonAddonLine2", addonLine2))
        usageMonitorSnapshotChanged := true

    if (UsageMonitorUpdateBar(usageMonitorHwndCodexDailyBar,   codexLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateBar(usageMonitorHwndCodexWeeklyBar,  codexLine2))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateBar(usageMonitorHwndClaudeDailyBar,  claudeLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateBar(usageMonitorHwndClaudeWeeklyBar, claudeLine2))
        usageMonitorSnapshotChanged := true
    if (usageMonitorHwndClaudeFableBar)
    {
        if (UsageMonitorUpdateBar(usageMonitorHwndClaudeFableBar, claudeLine3))
            usageMonitorSnapshotChanged := true
    }
    if (UsageMonitorUpdateBar(usageMonitorHwndGrokMonthlyBar,  grokLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateBar(usageMonitorHwndAddonLine1Bar, addonLine1))
        usageMonitorSnapshotChanged := true
    if (UsageMonitorUpdateBar(usageMonitorHwndAddonLine2Bar, addonLine2))
        usageMonitorSnapshotChanged := true

    if (usageMonitorViewMode = "mini")
    {
        usageMonitorClaudeAccountShort := UsageMonitorClaudeAccountShort(snapshot)
        signalText := usageMonitorShowClaudeAccountMini ? usageMonitorClaudeAccountShort : Chr(0x00B7)  ; "·" dot when hidden
        if (usageMonitorClaudeAccountShort = "")
            signalText := ""
        if (UsageMonitorSetCtrlText("UsageMonClaudeAccountSignal", signalText))
            usageMonitorSnapshotChanged := true
        ; Show a provider only if it has a usable percentage; a fully n/a / unavailable /
        ; No-Subscription column (e.g. Grok "W:n/a") is collapsed instead of shown dead.
        ; This repositions and resizes controls, so it is gated on the full input tuple:
        ; re-running it with identical inputs moves every control to where it already is,
        ; which at a faster cadence is a visible shudder across the HUD.
        miniKey := usageMonitorMiniCodexEligible . "|" . usageMonitorMiniClaudeEligible . "|" . usageMonitorMiniGrokEligible
            . "|" . codexDailyHasData . "|" . codexWeeklyHasData . "|" . claudeDailyHasData . "|" . claudeWeeklyHasData
            . "|" . grokMonthlyHasData . "|" . claudeNoSubscription . "|" . grokNoSubscription . "|" . claudeFableHasData
            . "|" . usageMonitorShowClaudeAccountMini . "|" . usageMonitorClaudeAccountShort
            . "|" . usageMonitorMiniCodexMode . "|" . usageMonitorMiniClaudeMode . "|" . usageMonitorMiniGrokMode
            . "|" . usageMonitorMiniAddonEligible . "|" . addonLine1HasData . "|" . addonLine2HasData
            . "|" . addonNoSubscription . "|" . usageMonitorMiniAddonMode
            . "|" . usageMonitorOffCodex . usageMonitorOffClaude . usageMonitorOffGrok . usageMonitorOffAddon
            . "|" . usageMonitorUiScale
        if (usageMonitorMiniLayoutKey != miniKey)
        {
            UsageMonitorSetMiniProvidersVisible(usageMonitorMiniCodexEligible, usageMonitorMiniClaudeEligible, usageMonitorMiniGrokEligible
                , codexDailyHasData, codexWeeklyHasData, claudeDailyHasData, claudeWeeklyHasData, grokMonthlyHasData
                , claudeNoSubscription, grokNoSubscription, claudeFableHasData
                , usageMonitorMiniAddonEligible, addonLine1HasData, addonLine2HasData, addonNoSubscription)
            usageMonitorMiniLayoutKey := miniKey
            usageMonitorSnapshotChanged := true
        }
    }
    else if (UsageMonitorUpdateMiniProviderToggleText())
        usageMonitorSnapshotChanged := true

    ; Provider headers are the only sign-in links. Keep the retired hint stub collapsed and
    ; let the sprite use its normal slot while the single status row reflows the footer.
    ; Both are one-shot per build - re-collapsing an already-collapsed stub or re-applying
    ; click-through to the same sprite only costs repaints.
    if (!usageMonitorLoginHintCollapsed)
    {
        GuiControl, UsageMon:Move, UsageMonLoginHint, % "h" . UsScale(1)
        GuiControl, UsageMon:Hide, UsageMonLoginHint
        usageMonitorLoginHintCollapsed := true
    }
    if (usageMonitorHwndSpritePlaceholder && usageMonitorViewMode = "full" && !usageMonitorHwndSprite)
        GuiControl, UsageMon:Show, UsageMonSpritePlaceholder
    if (usageMonitorHwndSprite && usageMonitorViewMode = "full" && usageMonitorSpriteApplied != usageMonitorHwndSprite)
    {
        GuiControl, UsageMon:Show, UsageMonSpriteCtrl
        UsageMonitorMakeSpriteClickThrough()
        usageMonitorSpriteApplied := usageMonitorHwndSprite
    }

    if (errorText = "")
    {
        if (status = "login_required")
        {
            loginProviders := UsageMonitorLoginProviderNames(snapshot)
            errorText := (loginProviders != "")
                ? loginProviders . " sign-in required. " . UsageMonitorLoginActionText(snapshot) . ", then Refresh."
                : "Sign-in required. Open the affected provider above, then Refresh."
        }
        else if (status = "partial")
            errorText := "Some values unavailable."
    }
    else
        errorText := UsageMonitorCompactErrorForDisplay(snapshot, status, errorText)
    if (UsageMonitorSetError(errorText))
        usageMonitorSnapshotChanged := true

    ; The heal is a synchronous whole-window RedrawWindow with RDW_ERASE. It is what keeps
    ; the themed statics correct, but running it on a tick that changed nothing is pure
    ; flicker - so it is spent only when something above actually moved.
    if (usageMonitorSnapshotChanged)
        UsageMonitorRepaintThemedStatics()
}

; Heal handler-missed paints after the ApplySnapshot burst: a WM_CTLCOLORSTATIC can still be
; dropped while the script thread is busy (its GuiControl text updates and PBM SendMessages
; force synchronous sibling repaints), leaving statics painted with their build-time color.
;
; Two things this deliberately does NOT do, both of which were bugs:
;   - It no longer skips the default theme. Metric lines are BUILT in the "text" color and
;     recolored good/warn/bad at runtime in BOTH themes, so a missed paint shows a plain grey
;     percentage in Default exactly as it shows a Default-blue header in Cyberpunk.
;   - It no longer merely invalidates. InvalidateRect only queues a WM_PAINT, so the heal was
;     serviced later — often during the uninterruptible opening of the very next timer thread,
;     which reproduced the same miss and re-latched the wrong color. RDW_UPDATENOW paints
;     synchronously, here and now, while the color map is known-good and the monitor (Critical
;     + MaxThreads 8) is guaranteed to answer.
UsageMonitorRepaintThemedStatics()
{
    global usageMonitorCtrlColors, usageMonitorHwnd

    if (!usageMonitorHwnd)
        return
    for hwnd, _ in usageMonitorCtrlColors
    {
        ; Hidden controls are skipped deliberately. A hidden window paints nothing, so
        ; invalidating one only dirties the parent underneath it - and in mini view a
        ; collapsed provider's controls could share a rect with a visible column, which turns
        ; the heal into the very wipe it exists to repair. (Parking in
        ; UsageMonitorSetMiniProvidersVisible removes that overlap; this is the second latch.)
        if (!DllCall("IsWindowVisible", "Ptr", hwnd))
            continue
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", true)
    }
    ; RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW
    DllCall("RedrawWindow", "Ptr", usageMonitorHwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0185)
}

UsageMonitorCleanupFetchFiles()
{
    global usageMonitorFetchOutFile, usageMonitorFetchStatusFile, usageMonitorFetchPid, usageMonitorFetchMode, usageMonitorFetchStartTick

    if (usageMonitorFetchOutFile != "")
        FileDelete, %usageMonitorFetchOutFile%
    if (usageMonitorFetchStatusFile != "")
        FileDelete, %usageMonitorFetchStatusFile%

    usageMonitorFetchOutFile := ""
    usageMonitorFetchStatusFile := ""
    usageMonitorFetchPid := 0
    usageMonitorFetchMode := ""
    usageMonitorFetchStartTick := 0
}

UsageMonitorPointInControl(hwnd, screenX, screenY, requireVisible := true, padding := 0)
{
    if (!hwnd)
        return false
    if (requireVisible && !DllCall("IsWindowVisible", "Ptr", hwnd))
        return false
    VarSetCapacity(rect, 16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", &rect)
    left   := NumGet(rect, 0, "Int") - padding
    top    := NumGet(rect, 4, "Int") - padding
    right  := NumGet(rect, 8, "Int") + padding
    bottom := NumGet(rect, 12, "Int") + padding
    return (screenX >= left && screenX < right && screenY >= top && screenY < bottom)
}

UsageMonitorGetWindowExStyle(hwnd)
{
    if (!hwnd)
        return 0
    return DllCall(A_PtrSize = 8 ? "GetWindowLongPtr" : "GetWindowLong"
        , "Ptr", hwnd, "Int", -20, "Ptr")
}

UsageMonitorSetWindowExStyle(hwnd, exStyle)
{
    if (!hwnd)
        return
    DllCall(A_PtrSize = 8 ? "SetWindowLongPtr" : "SetWindowLong"
        , "Ptr", hwnd, "Int", -20, "Ptr", exStyle, "Ptr")
}

UsageMonitorSetWindowExFlag(hwnd, flag, enable)
{
    currentStyle := UsageMonitorGetWindowExStyle(hwnd)
    nextStyle := enable ? (currentStyle | flag) : (currentStyle & ~flag)
    if (nextStyle != currentStyle)
        UsageMonitorSetWindowExStyle(hwnd, nextStyle)
}

UsageMonitorApplyWindowAlpha(alpha)
{
    global usageMonitorHwnd, usageMonitorWindowAlpha, usageMonitorWindowAlphaHwnd

    if (!usageMonitorHwnd)
        return

    if (alpha = "off")
    {
        if (usageMonitorWindowAlpha != "off" || usageMonitorWindowAlphaHwnd != usageMonitorHwnd)
        {
            UsageMonitorSetWindowExFlag(usageMonitorHwnd, 0x80000, false) ; WS_EX_LAYERED
            usageMonitorWindowAlpha := "off"
            usageMonitorWindowAlphaHwnd := usageMonitorHwnd
        }
        return
    }

    if (alpha != usageMonitorWindowAlpha || usageMonitorWindowAlphaHwnd != usageMonitorHwnd)
    {
        UsageMonitorSetWindowExFlag(usageMonitorHwnd, 0x80000, true) ; WS_EX_LAYERED
        DllCall("SetLayeredWindowAttributes"
            , "Ptr", usageMonitorHwnd
            , "UInt", 0
            , "UChar", alpha
            , "UInt", 0x2) ; LWA_ALPHA
        usageMonitorWindowAlpha := alpha
        usageMonitorWindowAlphaHwnd := usageMonitorHwnd
    }
}

UsageMonitorSetPassthrough(enable, alphaOverride := "")
{
    global usageMonitorHwnd, usageMonitorPassthroughActive, usageMonitorViewMode
    global usageMonitorFullNormalAlpha

    if (!usageMonitorHwnd)
        return

    if (usageMonitorViewMode = "mini")
    {
        if (usageMonitorPassthroughActive)
        {
            UsageMonitorSetWindowExFlag(usageMonitorHwnd, 0x20, false) ; WS_EX_TRANSPARENT
            usageMonitorPassthroughActive := false
        }
        UsageMonitorApplyWindowAlpha("off")
        return
    }

    desiredAlpha := (alphaOverride = "") ? usageMonitorFullNormalAlpha : alphaOverride
    if (enable != usageMonitorPassthroughActive)
    {
        if (enable)
            UsageMonitorSetWindowExFlag(usageMonitorHwnd, 0x20, true) ; WS_EX_TRANSPARENT
        else
            UsageMonitorSetWindowExFlag(usageMonitorHwnd, 0x20, false) ; WS_EX_TRANSPARENT
        usageMonitorPassthroughActive := enable
    }
    UsageMonitorApplyWindowAlpha(desiredAlpha)
}

UsageMonitorUpdatePassthrough()
{
    global usageMonitorHwnd, usageMonitorHwndRefreshBtn, usageMonitorHwndLoginHint, usageMonitorHwndHelp
    global usageMonitorHwndDragHandle, usageMonitorHwndCloseBtn
    global usageMonitorHwndClaudeAccount, usageMonitorHwndClaudeAccountToggle
    global usageMonitorHwndViewToggleBtn, usageMonitorHwndThemeBtn
    global usageMonitorHwndCodexMiniToggle, usageMonitorHwndClaudeMiniToggle, usageMonitorHwndGrokMiniToggle
    global usageMonitorHwndResetToggleBtn, usageMonitorCloseBtnShown
    global usageMonitorHwndCodexHeader, usageMonitorHwndClaudeHeader, usageMonitorHwndGrokHeader
    global usageMonitorHwndGrokMonthly, usageMonitorGrokLinkActive
    global usageMonitorHwndAddonHeader, usageMonitorHwndAddonMiniToggle
    global usageMonitorViewMode, usageMonitorFullNormalAlpha, usageMonitorFullHoverAlpha
    global usageMonitorTransparencyHoldUntilLeave, usageMonitorTransparencyHoldSawInside
    global usageMonitorIdleTier
    global usageMonitorHwndCodexSource, usageMonitorHwndGrokSource, usageMonitorHwndAddonSource

    CoordMode, Mouse, Screen
    MouseGetPos, mx, my

    WinGetPos, wx, wy, ww, wh, ahk_id %usageMonitorHwnd%
    overWindow := (mx >= wx && mx < wx + ww && my >= wy && my < wy + wh)

    if (usageMonitorViewMode = "mini")
    {
        if (usageMonitorCloseBtnShown)
        {
            GuiControl, UsageMon:Hide, UsageMonCloseBtn
            usageMonitorCloseBtnShown := false
        }
        UsageMonitorUpdateButtonVisuals(mx, my, overWindow)
        UsageMonitorUpdateMiniDotHover(overWindow)
        UsageMonitorSetPassthrough(false)
        return
    }

    if (!usageMonitorCloseBtnShown)
    {
        GuiControl, UsageMon:Show, UsageMonCloseBtn
        usageMonitorCloseBtnShown := true
    }

    ; Rebuilding from mini can produce a transient outside-window sample before
    ; the full popup settles. Require one confirmed inside sample, then clear
    ; the hold only after the cursor leaves the restored full popup.
    if (usageMonitorTransparencyHoldUntilLeave)
    {
        if (overWindow)
        {
            usageMonitorTransparencyHoldSawInside := true
            UsageMonitorUpdateButtonVisuals(mx, my, overWindow)
            UsageMonitorSetPassthrough(false, usageMonitorFullNormalAlpha)
            return
        }

        if (usageMonitorTransparencyHoldSawInside)
        {
            usageMonitorTransparencyHoldUntilLeave := false
            usageMonitorTransparencyHoldSawInside := false
        }
        else
        {
            UsageMonitorUpdateButtonVisuals(mx, my, overWindow)
            UsageMonitorSetPassthrough(false, usageMonitorFullNormalAlpha)
            return
        }
    }

    UsageMonitorUpdateButtonVisuals(mx, my, overWindow)

    if (!overWindow)
    {
        ; Click-through only matters once the cursor is inside. Asleep in the background tier the
        ; popup keeps taking the mouse instead, so the first hover can wake it (WM_MOUSEMOVE).
        UsageMonitorSetPassthrough(usageMonitorIdleTier != "background", usageMonitorFullNormalAlpha)
        return
    }

    hoverAlpha := usageMonitorFullHoverAlpha
    controlAlpha := usageMonitorFullNormalAlpha
    controlPad := UsScale(6)

    ; Keep interactive controls and their small border zones readable/clickable.
    if (UsageMonitorPointInControl(usageMonitorHwndDragHandle, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndCloseBtn, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndRefreshBtn, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndViewToggleBtn, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndThemeBtn, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndCodexHeader, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndClaudeHeader, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndGrokHeader, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndAddonHeader, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    ; Source tags carry a hover tooltip, so they stay opaque like the headers beside them.
    if (UsageMonitorPointInControl(usageMonitorHwndCodexSource, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndGrokSource, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndAddonSource, mx, my, true, controlPad)
        || (UsageMonitorClaudeSourceIsCli() && UsageMonitorPointInControl(usageMonitorHwndClaudeAccount, mx, my, true, controlPad)))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndCodexMiniToggle, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndClaudeMiniToggle, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndGrokMiniToggle, mx, my, true, controlPad)
        || UsageMonitorPointInControl(usageMonitorHwndAddonMiniToggle, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndResetToggleBtn, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorClaudeAccountSwitchEnabled() && UsageMonitorPointInControl(usageMonitorHwndClaudeAccount, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    ; The eye toggle is always visible and must stay clickable/opaque on hover.
    if (UsageMonitorPointInControl(usageMonitorHwndClaudeAccountToggle, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    if (UsageMonitorPointInControl(usageMonitorHwndLoginHint, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }
    ; When Grok failed, the Weekly line is a clickable "Open Grok" link — keep it opaque so
    ; the click lands (same guard the top-bar buttons use).
    if (usageMonitorGrokLinkActive && UsageMonitorPointInControl(usageMonitorHwndGrokMonthly, mx, my, true, controlPad))
    {
        UsageMonitorSetPassthrough(false, controlAlpha)
        return
    }

    UsageMonitorSetPassthrough(true, hoverAlpha)
}

UsageMonitorAutoRefreshTimer:
    if (!usageMonitorVisible)
        return
    if (usageMonitorIdleTier = "background")
    {
        ; No tracking tick runs in background, so this tick is what notices the user went away.
        ; A tier change settles refresh itself (away stops it; the others resume it).
        UsageMonitorSetIdleTier(UsageMonitorDesiredIdleTier())
        if (usageMonitorIdleTier != "background")
            return
    }
    if (UsageMonitorTierRefreshes(usageMonitorIdleTier))
        UsageMonitorRequestRefresh(true)   ; silent: values change in place, no load cycle
return

; Self-contained tooltip-clear for the standalone "VS Code is not running" quick-tip.
; Named uniquely (not HideQuickTip) to avoid a duplicate-label clash with a host script's own
; labels when this file is #included there.
UsageMonitorHideQuickTip:
    ToolTip
return

UsageMonitorTrackAnchor:
    if (usageMonitorVisible)
    {
        ; Yield z-order to the host's listed windows (usageMonitorHostYieldWindows). Only the
        ; z-order step is skipped: parking and idle tiers must keep running, or a lingering overlay
        ; would leave the popup stranded on screen with no tracked window behind it.
        UsageMonitorTrackWindowState(UsageMonitorYieldWindowPresent())
        if (usageMonitorVisible)   ; that pass parks the popup when no tracked window is left
        {
            UsageMonitorApplyAnchor()
            if (!usageMonitorDragInProgress)
                UsageMonitorUpdatePassthrough()
            UsageMonitorSetIdleTier(UsageMonitorDesiredIdleTier())
        }
    }
return

UsageMonitorIdleWakeTimer:
    UsageMonitorIdleWakeCheck()
return

UsageMonitorParkedPollTimer:
    UsageMonitorParkedPoll()
return

UsageMonitorFocusBorderCheck:
    ; Only stop polling when the overlay is genuinely hidden (the show path re-arms this
    ; timer). A transient hwnd=0 during an 'm' rebuild must NOT switch the timer off, or the
    ; border can be left "stuck on" if focus moves elsewhere before the rebuild re-arms it.
    if (!usageMonitorVisible)
    {
        UsageMonitorHideFocusBorder()
        SetTimer, UsageMonitorFocusBorderCheck, Off
    }
    else if (!usageMonitorHwnd || !WinActive("ahk_id " . usageMonitorHwnd) || usageMonitorDragInProgress)
    {
        UsageMonitorRememberPrevActiveWindow()
        UsageMonitorHideFocusBorder()
    }
    else
        UsageMonitorShowFocusBorder()
return

UsageMonitorDeferredSpriteBuild:
    UsageMonitorBuildSprite()
return

UsageMonitorButtonPressFallback:
    UsageMonitorReleasePressedButton()
return

UsageMonGuiSize:
    if (usageMonitorVisible)
        UsageMonitorApplyAnchor()
return

UsageMonBtnRefresh:
    if (usageMonitorVisible)
        UsageMonitorRequestRefresh()
return

UsageMonBtnToggleView:
    if (usageMonitorVisible)
        UsageMonitorToggleViewMode()
return

UsageMonBtnToggleTheme:
    if (usageMonitorVisible)
        UsageMonitorToggleTheme()
return

UsageMonBtnToggleResets:
    if (usageMonitorVisible)
        UsageMonitorToggleResetDates()
return

UsageMonBtnOpenCodex:
    if (usageMonitorVisible)
        UsageMonitorOpenCodexPage()
return

UsageMonBtnOpenClaude:
    if (usageMonitorVisible)
        UsageMonitorOpenClaudePage()
return

UsageMonBtnOpenGrokHeader:
    if (usageMonitorVisible)
        UsageMonitorOpenGrokPage()
return

UsageMonBtnOpenGrok:
    ; Guard on the link being active — the gLabel stays attached to the Weekly text even when
    ; Grok is healthy, and with the window focused/opaque a click can land there despite the
    ; passthrough hit-zone. A healthy "Weekly: 45%" line must not open Grok.
    if (usageMonitorVisible && usageMonitorGrokLinkActive)
        UsageMonitorOpenGrokPage()
return

UsageMonBtnOpenAddonHeader:
    if (usageMonitorVisible)
        UsageMonitorOpenAddonPage()
return

UsageMonitorMiniResetsPanelTimeout:
    UsageMonitorHideMiniResetsPanel()
return

UsageMonBtnSwitchClaudeAccount:
    if (usageMonitorVisible)
        UsageMonitorSwitchClaudeAccount()
return

UsageMonBtnToggleClaudeAccount:
    if (usageMonitorVisible)
        UsageMonitorToggleClaudeAccountFull()
return

UsageMonBtnToggleClaudeAccountMini:
    if (usageMonitorVisible)
        UsageMonitorToggleClaudeAccountMini()
return

UsageMonBtnHideMiniCodex:
    if (usageMonitorVisible)
        UsageMonitorSetMiniProviderVisible("codex", false)
return

UsageMonBtnHideMiniClaude:
    if (usageMonitorVisible)
        UsageMonitorSetMiniProviderVisible("claude", false)
return

UsageMonBtnHideMiniGrok:
    if (usageMonitorVisible)
        UsageMonitorSetMiniProviderVisible("grok", false)
return

UsageMonBtnHideMiniAddon:
    if (usageMonitorVisible)
        UsageMonitorSetMiniProviderVisible("addon", false)
return

UsageMonBtnToggleMiniAddon:
    if (usageMonitorVisible)
        UsageMonitorToggleMiniProvider("addon")
return

UsageMonBtnToggleMiniCodex:

    if (usageMonitorVisible)
        UsageMonitorToggleMiniProvider("codex")
return

UsageMonBtnToggleMiniClaude:
    if (usageMonitorVisible)
        UsageMonitorToggleMiniProvider("claude")
return

UsageMonBtnToggleMiniGrok:
    if (usageMonitorVisible)
        UsageMonitorToggleMiniProvider("grok")
return

UsageMonBtnClose:
    HideUsageMonitorPopup()
return

UsageMonDragHandle:
return

UsageMonitorPollSnapshot:
    global usageMonitorFetchInFlight, usageMonitorFetchPid, usageMonitorFetchMode, usageMonitorFetchStartTick
    global usageMonitorFetchOutFile, usageMonitorFetchStatusFile, usageMonitorNodePromptHandled

    if (!usageMonitorFetchInFlight)
    {
        SetTimer, UsageMonitorPollSnapshot, Off
        return
    }

    Process, Exist, %usageMonitorFetchPid%
    if (ErrorLevel = usageMonitorFetchPid)
    {
        elapsedMs := A_TickCount - usageMonitorFetchStartTick
        maxWaitMs := 55000
        if (elapsedMs > maxWaitMs)
        {
            Process, Close, %usageMonitorFetchPid%
            SetTimer, UsageMonitorPollSnapshot, Off
            usageMonitorFetchInFlight := false
            UsageMonitorSetState("Idle (timeout)")
            UsageMonitorSetError("Timed out. Press R to retry.")
            ; Back off to the idle tier: a snapshot slow enough to hit the watchdog is the
            ; last thing that should be retried at the fast cadence.
            usageMonitorRefreshIdleStreak := usageMonitorRefreshIdleStreakMax
            UsageMonitorScheduleAutoRefresh()
            UsageMonitorCleanupFetchFiles()
            UsageMonitorRunQueuedRefresh()
        }
        return
    }

    SetTimer, UsageMonitorPollSnapshot, Off
    usageMonitorFetchInFlight := false

    snapshot := UsageMonitorReadSnapshot(usageMonitorFetchOutFile)
    status := UsageMonitorReadStatus(usageMonitorFetchStatusFile)

    errorCode := UsageMonitorValue(snapshot, "error_code", "")
    if (errorCode = "node_missing")
    {
        UsageMonitorCleanupFetchFiles()
        if (!usageMonitorNodePromptHandled)
            UsageMonitorPromptNodeInstall()
        return
    }

    ; Fall back to prior data for failed providers when a good prior snapshot exists
    codexFail  := (UsageMonitorValue(snapshot, "codex_status",  "error") = "error")
    claudeFail := (UsageMonitorValue(snapshot, "claude_status", "error") = "error")
    lastGoodStatus := usageMonitorLastSnapshotStatus
    hasPriorGood := (IsObject(usageMonitorLastSnapshot) && (lastGoodStatus = "ok" || lastGoodStatus = "partial"))
    currentClaudeProfile := UsageMonitorValue(snapshot, "claude_profile", "")
    lastClaudeProfile := UsageMonitorValue(usageMonitorLastSnapshot, "claude_profile", "")
    sameClaudeProfile := (currentClaudeProfile = "" || lastClaudeProfile = "" || currentClaudeProfile = lastClaudeProfile)

    if (codexFail && claudeFail && hasPriorGood && sameClaudeProfile)
    {
        displaySnapshot := usageMonitorLastSnapshot.Clone()
        UsageMonitorKeepOffRows(displaySnapshot, snapshot)
        displaySnapshot["error"] := UsageMonitorBuildRefreshFallbackError(snapshot, "Refresh failed - showing prior data.")
        displaySnapshot["overall_status"] := "partial"
        UsageMonitorApplySnapshot(displaySnapshot, "partial")
        UsageMonitorAfterSnapshotApplied()
        UsageMonitorCleanupFetchFiles()
        UsageMonitorRunQueuedRefresh()
        return
    }
    ; Prior data stands in for a failed provider, but never for one that was off before (it has
    ; no numbers to show).
    else if (claudeFail && hasPriorGood && sameClaudeProfile && UsageMonitorValue(usageMonitorLastSnapshot, "claude_status", "") != "off")
    {
        fallbackError := UsageMonitorBuildRefreshFallbackError(snapshot, "Claude refresh failed - showing prior data.")
        snapshot["claude_status"]            := UsageMonitorValue(usageMonitorLastSnapshot, "claude_status", "error")
        snapshot["claude_source"]            := UsageMonitorValue(usageMonitorLastSnapshot, "claude_source", "")
        snapshot["claude_line_1"]            := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_1", "Daily: unavailable")
        snapshot["claude_line_2"]            := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_2", "Weekly: unavailable")
        snapshot["claude_line_3"]            := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_3", "")
        snapshot["claude_line_1_reset_text"] := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_1_reset_text", "")
        snapshot["claude_line_2_reset_text"] := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_2_reset_text", "")
        snapshot["claude_line_3_reset_text"] := UsageMonitorValue(usageMonitorLastSnapshot, "claude_line_3_reset_text", "")
        snapshot["claude_account_label"]     := UsageMonitorValue(usageMonitorLastSnapshot, "claude_account_label", "")
        snapshot["claude_profile"]           := UsageMonitorValue(usageMonitorLastSnapshot, "claude_profile", "")
        snapshot["claude_profile_choices"]   := UsageMonitorValue(usageMonitorLastSnapshot, "claude_profile_choices", "")
        snapshot["claude_next_profile"]      := UsageMonitorValue(usageMonitorLastSnapshot, "claude_next_profile", "")
        snapshot["claude_profile_switch_available"] := UsageMonitorValue(usageMonitorLastSnapshot, "claude_profile_switch_available", "0")
        snapshot["error"] := fallbackError
        snapshot["overall_status"] := "partial"
        status := "partial"
    }
    else if (codexFail && hasPriorGood && UsageMonitorValue(usageMonitorLastSnapshot, "codex_status", "") != "off")
    {
        fallbackError := UsageMonitorBuildRefreshFallbackError(snapshot, "Codex refresh failed - showing prior data.")
        snapshot["codex_status"]            := UsageMonitorValue(usageMonitorLastSnapshot, "codex_status", "error")
        snapshot["codex_source"]            := UsageMonitorValue(usageMonitorLastSnapshot, "codex_source", "")
        snapshot["codex_line_1"]            := UsageMonitorValue(usageMonitorLastSnapshot, "codex_line_1", "Daily: unavailable")
        snapshot["codex_line_2"]            := UsageMonitorValue(usageMonitorLastSnapshot, "codex_line_2", "Weekly: unavailable")
        snapshot["codex_line_1_reset_text"] := UsageMonitorValue(usageMonitorLastSnapshot, "codex_line_1_reset_text", "")
        snapshot["codex_line_2_reset_text"] := UsageMonitorValue(usageMonitorLastSnapshot, "codex_line_2_reset_text", "")
        snapshot["error"] := fallbackError
        snapshot["overall_status"] := "partial"
        status := "partial"
    }

    UsageMonitorApplySnapshot(snapshot, status)
    UsageMonitorAfterSnapshotApplied()
    UsageMonitorCleanupFetchFiles()
    UsageMonitorRunQueuedRefresh()
return

UsageMonGuiClose:
UsageMonGuiEscape:
    HideUsageMonitorPopup()
return

UsageMonitorQueuedRefreshTimer:
    UsageMonitorRequestRefresh()
return

; A provider switched off since the prior snapshot keeps its Off row when prior data stands in.
UsageMonitorKeepOffRows(displaySnapshot, snapshot)
{
    local index, provider, keyIndex, suffix

    for index, provider in ["codex", "claude", "grok", "addon"]
    {
        if (UsageMonitorValue(snapshot, provider . "_status", "") != "off")
            continue
        for keyIndex, suffix in ["_status", "_source", "_line_1", "_line_2", "_line_3"]
            displaySnapshot[provider . suffix] := UsageMonitorValue(snapshot, provider . suffix, "")
    }
}

; Settings asked for a refresh while a fetch was running: run it once that fetch has finished.
UsageMonitorRunQueuedRefresh()
{
    global usageMonitorRefreshQueued

    if (!usageMonitorRefreshQueued)
        return
    usageMonitorRefreshQueued := false
    SetTimer, UsageMonitorQueuedRefreshTimer, -50
}

UsageMonitorPromptNodeInstall()
{
    global usageMonitorNodeInstallInFlight, usageMonitorNodePromptHandled, usageMonitorDataDir

    if (usageMonitorNodeInstallInFlight)
        return

    usageMonitorNodePromptHandled := true

    ; Say exactly what Yes does before it runs (Get-LLMUsageSnapshot.ps1 -Mode Install):
    ; winget accepts agreements on the user's behalf, and the zip fallback's target folder.
    promptMsg := "Node.js is required but was not found on this system."
        . "`n`nInstall Node.js (LTS) for your user account now? No admin rights are needed, and this app does not change your PATH."
        . "`n`nWith winget available, it runs ""winget install OpenJS.NodeJS.LTS --scope user"", which accepts the winget source and package agreements on your behalf."
        . "`nWithout winget, it downloads the official Node.js zip from nodejs.org, checks it against the published SHA-256 and unpacks it into:"
        . "`n" . usageMonitorDataDir . "\node"
        . "`n`nYes = Install now"
        . "`nNo = Skip (usage monitor will not work)"

    MsgBox, 0x24, LLM Usage Monitor, %promptMsg%
    IfMsgBox, Yes
    {
        UsageMonitorStartNodeInstall()
        return
    }
    UsageMonitorSetError("Node.js is required. Press R to retry.")
}

UsageMonitorStartNodeInstall()
{
    global usageMonitorNodeInstallInFlight, usageMonitorNodeInstallPid
    global usageMonitorNodeInstallOutFile, usageMonitorNodeInstallStatusFile
    global usageMonitorDir, usageMonitorDataDir

    workDir := usageMonitorDir
    scriptPath := workDir . "\Get-LLMUsageSnapshot.ps1"

    psExe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (!FileExist(psExe))
        psExe := "powershell.exe"

    tmpDir := usageMonitorDataDir . "\tmp"
    if (!InStr(FileExist(tmpDir), "D"))
        FileCreateDir, %tmpDir%
    outFile := tmpDir . "\llm-node-install-out-" . A_Now . "-" . A_TickCount . ".txt"
    statusFile := tmpDir . "\llm-node-install-status-" . A_Now . "-" . A_TickCount . ".txt"
    FileDelete, %outFile%
    FileDelete, %statusFile%

    runTarget := """" . psExe . """ -NoProfile -ExecutionPolicy Bypass -File """ . scriptPath
        . """ -Mode Install -OutFile """ . outFile . """ -StatusFile """ . statusFile . """ -DataDir """ . usageMonitorDataDir . """"

    UsageMonitorSetError("Installing Node.js...")
    UsageMonitorSetState("Installing...")

    Run, %runTarget%, %workDir%, Hide UseErrorLevel, launchPid
    if (ErrorLevel = "ERROR" || launchPid = 0)
    {
        UsageMonitorSetError("Could not start Node.js installer.")
        return
    }

    usageMonitorNodeInstallInFlight := true
    usageMonitorNodeInstallPid := launchPid
    usageMonitorNodeInstallOutFile := outFile
    usageMonitorNodeInstallStatusFile := statusFile
    SetTimer, UsageMonitorPollNodeInstall, 500
}

UsageMonitorPollNodeInstall:
    global usageMonitorNodeInstallInFlight, usageMonitorNodeInstallPid
    global usageMonitorNodeInstallOutFile, usageMonitorNodeInstallStatusFile

    if (!usageMonitorNodeInstallInFlight)
    {
        SetTimer, UsageMonitorPollNodeInstall, Off
        return
    }

    Process, Exist, %usageMonitorNodeInstallPid%
    if (ErrorLevel = usageMonitorNodeInstallPid)
        return

    SetTimer, UsageMonitorPollNodeInstall, Off
    usageMonitorNodeInstallInFlight := false

    installStatus := ""
    if (usageMonitorNodeInstallStatusFile != "" && FileExist(usageMonitorNodeInstallStatusFile))
    {
        FileRead, installStatusRaw, %usageMonitorNodeInstallStatusFile%
        installStatus := Trim(installStatusRaw, " `t`r`n")
    }

    if (usageMonitorNodeInstallOutFile != "")
        FileDelete, %usageMonitorNodeInstallOutFile%
    if (usageMonitorNodeInstallStatusFile != "")
        FileDelete, %usageMonitorNodeInstallStatusFile%
    usageMonitorNodeInstallOutFile := ""
    usageMonitorNodeInstallStatusFile := ""
    usageMonitorNodeInstallPid := 0

    if (installStatus = "ok")
    {
        UsageMonitorSetError("Node.js installed. Refreshing...")
        UsageMonitorTriggerRefresh()
    }
    else
    {
        UsageMonitorSetError("Node.js install failed. Install Node 18+ from nodejs.org")
    }
return

UsageMonitorRestoreIfWasVisible()
{
    global usageMonitorStatePath, usageMonitorGlobalsReady

    if (!usageMonitorGlobalsReady)
        return
    IniRead, wasVisible, %usageMonitorStatePath%, State, visible, 0
    if (wasVisible != "1")
        return
    ; At login nothing is usually open yet: park and wait for a tracked window instead of giving up.
    if (!ShowUsageMonitorPopup(true))
        UsageMonitorParkPopup()
}

; --- Settings window (release plan D5) ---------------------------------------------------
; One small dialog for what people change: the hotkey (standalone host only), each provider's
; login source or Off, the Claude Firefox profile, docking, refresh cadence and theme. It opens from
; the standalone tray ("Settings...") and from the O key on the focused popup in both hosts.
; Save writes only the keys that changed (both hosts can share one settings.ini) and applies them
; at once. Text uses the popup palette's text roles, which theme-contrast.test.mjs checks against
; bg; the native controls take Windows' dark style where the OS has it (1809 and later).
; The title avoids "LLM Usage Monitor" so title matches for the popup can never catch it.
UsageMonitorShowSettings()
{
    local init, hostLabel, profiles, choices, index, name, refreshLabels, refreshValues
    local seconds, legacyMs, refreshPick, profilePick, profileItems, refreshItems, ddlItems, profileState
    local px, py, pw, ph, waLeft, waTop, waRight, waBottom, mx, my, sx, sy, sw, sh, value, hwndCtrl
    local hHotkey, hCodex, hClaude, hGrok, hAddon, hProfile, hAnchor, hRefresh, hTheme, hSave, hCancel
    local prevDetectHidden

    if (!usageMonitorGlobalsReady)
        return false
    if (usageMonitorSettingsHwnd && WinExist("ahk_id " . usageMonitorSettingsHwnd))
    {
        WinActivate, ahk_id %usageMonitorSettingsHwnd%
        return true
    }
    hHotkey := 0, hCodex := 0, hClaude := 0, hGrok := 0, hAddon := 0, hProfile := 0
    hAnchor := 0, hRefresh := 0, hTheme := 0, hSave := 0, hCancel := 0

    UsageMonitorLoadProviderPrefs()
    UsageMonitorLoadTheme()
    UsageMonitorLoadAnchorMode()
    UsageMonitorLoadClaudeProfile()

    init := {}
    ; Only the standalone host defines these; under any other host the hotkey row is read-only.
    init.hotkeyEditable := IsFunc("UsageMonitorStandaloneApplyHotkey") ? true : false
    init.hotkey := init.hotkeyEditable ? Func("UsageMonitorStandaloneCurrentHotkey").Call() : ""
    init.codex := UsageMonitorProviderPref("codex")
    init.claude := UsageMonitorProviderPref("claude")
    init.grok := UsageMonitorProviderPref("grok")
    init.addon := UsageMonitorProviderPref("addon")
    init.profile := usageMonitorClaudeProfile
    init.anchor := usageMonitorAnchorMode
    init.theme := usageMonitorTheme

    ; Refresh: the adaptive cadence or a fixed one. An unlisted saved value, or the older
    ; [Debug] autoRefreshMs while refreshSeconds is unset, gets an item of its own.
    refreshLabels := ["Adaptive (15 s to 1 min)", "Every 1 min", "Every 2 min", "Every 5 min", "Every 15 min"]
    refreshValues := [0, 60, 120, 300, 900]
    IniRead, seconds, %usageMonitorStatePath%, Settings, refreshSeconds, %A_Space%
    seconds := Trim(seconds, " `t`r`n")
    refreshPick := 1
    if (RegExMatch(seconds, "^\d+$"))
    {
        seconds := seconds + 0
        refreshPick := 0
        for index, value in refreshValues
        {
            if (value = seconds)
                refreshPick := index
        }
        if (!refreshPick)
        {
            refreshLabels.Push("Every " . seconds . " s")
            refreshValues.Push(seconds)
            refreshPick := refreshValues.Length()
        }
    }
    else
    {
        IniRead, legacyMs, %usageMonitorStatePath%, Debug, autoRefreshMs, 0
        legacyMs := legacyMs + 0
        if (legacyMs > 0)
        {
            refreshLabels.Push("Custom (" . Round(legacyMs / 1000) . " s, from [Debug])")
            refreshValues.Push("legacy")
            refreshPick := refreshValues.Length()
        }
    }
    init.refresh := refreshValues[refreshPick]
    init.refreshValues := refreshValues
    refreshItems := ""
    for index, value in refreshLabels
        refreshItems .= (index > 1 ? "|" : "") . value

    ; Claude's Firefox profiles: the signed-in ones the last snapshot listed, plus the saved one.
    profiles := []
    choices := StrSplit(usageMonitorClaudeProfileChoices, "|")
    for index, name in choices
    {
        name := UsageMonitorSafeProfileName(name)
        if (name != "")
            profiles.Push(name)
    }
    profilePick := 1
    for index, name in profiles
    {
        if (name = init.profile)
            profilePick := index + 1
    }
    if (init.profile != "" && profilePick = 1)
    {
        profiles.Push(init.profile)
        profilePick := profiles.Length() + 1
    }
    init.profileNames := profiles
    profileItems := "Automatic"
    for index, name in profiles
        profileItems .= "|" . name
    usageMonitorSettingsInitial := init

    Gui, UsageMonSettings:New, +HwndusageMonitorSettingsHwnd +AlwaysOnTop -MinimizeBox -MaximizeBox, Usage Monitor Settings
    Gui, UsageMonSettings:Margin, 16, 12
    Gui, UsageMonSettings:Color, % UsageMonitorThemeRgb("bg"), % UsageMonitorThemeRgb("track")

    UsageMonitorSettingsFont("header", 10, "Bold")
    Gui, UsageMonSettings:Add, Text, xm w330, Hotkey
    UsageMonitorSettingsFont("text", 9)
    Gui, UsageMonSettings:Add, Text, xm y+10 w110, Open the popup
    if (init.hotkeyEditable)
    {
        Gui, UsageMonSettings:Add, Edit, x130 yp-3 w200 r1 vUsageMonSetHotkey HwndhHotkey, % UsageMonitorHotkeyToText(init.hotkey)
        UsageMonitorSettingsFont("dim", 8)
        Gui, UsageMonSettings:Add, Text, x130 y+3 w200, e.g. Ctrl+Alt+Y or Win+Shift+U
    }
    else
    {
        hostLabel := usageMonitorHostHotkeyLabel
        UsageMonitorSettingsFont("dim", 9)
        Gui, UsageMonSettings:Add, Text, x130 yp w200, % (hostLabel != "") ? hostLabel : "Set by the host script"
    }

    UsageMonitorSettingsFont("header", 10, "Bold")
    Gui, UsageMonSettings:Add, Text, xm y+16 w330, Providers
    UsageMonitorSettingsFont("text", 9)
    ddlItems := "Off|Auto (CLI, then Firefox)|CLI only|Firefox only"
    Gui, UsageMonSettings:Add, Text, xm y+10 w110, Codex
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetCodex HwndhCodex Choose" . UsageMonitorSourcePrefIndex(init.codex), %ddlItems%
    Gui, UsageMonSettings:Add, Text, xm y+9 w110, Claude
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetClaude HwndhClaude gUsageMonSettingsClaudeChanged Choose" . UsageMonitorSourcePrefIndex(init.claude), %ddlItems%
    Gui, UsageMonSettings:Add, Text, xm y+9 w110, Grok
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetGrok HwndhGrok Choose" . UsageMonitorSourcePrefIndex(init.grok), %ddlItems%
    ; The add-on row exists only when the host named an add-on module; its label and warning
    ; are the module's own (from the last snapshot). Off means the module is not even loaded.
    if (usageMonitorAddonActive)
    {
        Gui, UsageMonSettings:Add, Text, xm y+9 w110, % UsageMonitorAddonDisplayLabel()
        Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetAddon HwndhAddon Choose" . ((init.addon = "on") ? 2 : 1), Off|On
        if (usageMonitorAddonWarning != "")
        {
            UsageMonitorSettingsFont("warn", 8)
            Gui, UsageMonSettings:Add, Text, x130 y+3 w200, % usageMonitorAddonWarning
            UsageMonitorSettingsFont("text", 9)
        }
    }
    profileState := (init.claude = "auto" || init.claude = "firefox") ? "" : " Disabled"
    Gui, UsageMonSettings:Add, Text, xm y+10 w110, Claude profile
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetProfile HwndhProfile Choose" . profilePick . profileState, %profileItems%
    UsageMonitorSettingsFont("dim", 8)
    Gui, UsageMonSettings:Add, Text, x130 y+3 w200, The Firefox profile Claude reads (Auto or Firefox only).

    UsageMonitorSettingsFont("header", 10, "Bold")
    Gui, UsageMonSettings:Add, Text, xm y+16 w330, Display
    UsageMonitorSettingsFont("text", 9)
    Gui, UsageMonSettings:Add, Text, xm y+10 w110, Position
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetAnchor HwndhAnchor Choose" . ((init.anchor = "apps") ? 2 : 1), Float on screen|Dock to tracked apps
    Gui, UsageMonSettings:Add, Text, xm y+9 w110, Refresh
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetRefresh HwndhRefresh Choose" . refreshPick, %refreshItems%
    Gui, UsageMonSettings:Add, Text, xm y+9 w110, Theme
    Gui, UsageMonSettings:Add, DropDownList, % "x130 yp-3 w200 AltSubmit vUsageMonSetTheme HwndhTheme Choose" . ((init.theme = "cyberpunk") ? 2 : 1), Default|Cyberpunk

    UsageMonitorSettingsFont("bad", 8)
    Gui, UsageMonSettings:Add, Text, xm y+12 w330 h30 vUsageMonSetError
    UsageMonitorSettingsFont("text", 9)
    Gui, UsageMonSettings:Add, Button, x166 y+4 w84 h26 Default gUsageMonSettingsBtnSave HwndhSave, Save
    Gui, UsageMonSettings:Add, Button, x262 yp w84 h26 gUsageMonSettingsBtnCancel HwndhCancel, Cancel

    if (UsageMonitorWindowsBuild() >= 17763)
    {
        for index, hwndCtrl in [hHotkey, hCodex, hClaude, hGrok, hAddon, hProfile, hAnchor, hRefresh, hTheme]
        {
            if (hwndCtrl)
                DllCall("uxtheme\SetWindowTheme", "Ptr", hwndCtrl, "Str", "DarkMode_CFD", "Ptr", 0)
        }
        for index, hwndCtrl in [hSave, hCancel]
            DllCall("uxtheme\SetWindowTheme", "Ptr", hwndCtrl, "Str", "DarkMode_Explorer", "Ptr", 0)
        ; Dark title bar: attribute 20 since Windows 10 20H1, 19 before it.
        if (DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", usageMonitorSettingsHwnd, "UInt", 20, "Int*", 1, "UInt", 4) != 0)
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", usageMonitorSettingsHwnd, "UInt", 19, "Int*", 1, "UInt", 4)
    }

    ; Centered on the popup's monitor, or on the cursor's when the popup is not on screen.
    prevDetectHidden := A_DetectHiddenWindows
    DetectHiddenWindows, On
    Gui, UsageMonSettings:Show, AutoSize Hide
    WinGetPos, , , sw, sh, ahk_id %usageMonitorSettingsHwnd%
    DetectHiddenWindows, %prevDetectHidden%
    if (usageMonitorVisible && usageMonitorHwnd)
    {
        WinGetPos, px, py, pw, ph, ahk_id %usageMonitorHwnd%
    }
    else
    {
        CoordMode, Mouse, Screen
        MouseGetPos, mx, my
        px := mx, py := my, pw := 1, ph := 1
    }
    UsageMonitorGetMonitorWorkAreaForRect(px, py, pw, ph, waLeft, waTop, waRight, waBottom)
    sx := waLeft + ((waRight - waLeft - sw) // 2)
    sy := waTop + ((waBottom - waTop - sh) // 2)
    Gui, UsageMonSettings:Show, x%sx% y%sy%
    return true
}

UsageMonitorSettingsFont(role, size, weight := "Norm")
{
    Gui, UsageMonSettings:Font, % "s" . size . " " . weight . " c" . UsageMonitorThemeRgb(role), Segoe UI
}

; DDL position of a source choice: 1 Off, 2 Auto (CLI, then Firefox), 3 CLI only, 4 Firefox only.
UsageMonitorSourcePrefIndex(pref)
{
    if (pref = "off")
        return 1
    if (pref = "cli")
        return 3
    if (pref = "firefox")
        return 4
    return 2
}

UsageMonitorWindowsBuild()
{
    local parts
    parts := StrSplit(A_OSVersion, ".")
    return (parts.Length() >= 3) ? parts[3] + 0 : 0
}

UsageMonitorSettingsShowError(text)
{
    GuiControl, UsageMonSettings:, UsageMonSetError, %text%
}

UsageMonitorCloseSettings()
{
    global usageMonitorSettingsHwnd
    if (usageMonitorSettingsHwnd)
        Gui, UsageMonSettings:Destroy
    usageMonitorSettingsHwnd := 0
}

; The Claude profile matters only while Claude may read Firefox (Auto or Firefox only).
UsageMonitorSettingsSyncProfileRow()
{
    local claudeIndex
    GuiControlGet, claudeIndex, UsageMonSettings:, UsageMonSetClaude
    GuiControl, % "UsageMonSettings:Enable" . ((claudeIndex = 2 || claudeIndex = 4) ? 1 : 0), UsageMonSetProfile
}

; Writes the key only when its value changed; true when it did.
UsageMonitorSettingsWriteIfChanged(section, key, newValue, oldValue)
{
    global usageMonitorStatePath
    if (newValue == oldValue)
        return false
    IniWrite, %newValue%, %usageMonitorStatePath%, %section%, %key%
    return true
}

UsageMonitorSettingsSave()
{
    local init, newHotkey, errorText, err, prefOrder, codex, claude, grok, addon, profile, anchor, refresh, theme
    local codexIndex, claudeIndex, grokIndex, addonIndex, profileIndex, anchorIndex, refreshIndex, themeIndex, hotkeyText
    local providersChanged, profileChanged, anchorChanged, refreshChanged, themeChanged

    if (!usageMonitorSettingsHwnd)
        return
    init := usageMonitorSettingsInitial
    ; Read every control directly (a disabled one included), not through Submit.
    GuiControlGet, codexIndex, UsageMonSettings:, UsageMonSetCodex
    GuiControlGet, claudeIndex, UsageMonSettings:, UsageMonSetClaude
    GuiControlGet, grokIndex, UsageMonSettings:, UsageMonSetGrok
    addonIndex := 0
    if (usageMonitorAddonActive)
        GuiControlGet, addonIndex, UsageMonSettings:, UsageMonSetAddon
    GuiControlGet, profileIndex, UsageMonSettings:, UsageMonSetProfile
    GuiControlGet, anchorIndex, UsageMonSettings:, UsageMonSetAnchor
    GuiControlGet, refreshIndex, UsageMonSettings:, UsageMonSetRefresh
    GuiControlGet, themeIndex, UsageMonSettings:, UsageMonSetTheme

    ; The hotkey first: a key that cannot be registered keeps the old one and saves nothing.
    newHotkey := "", errorText := ""
    if (init.hotkeyEditable)
    {
        GuiControlGet, hotkeyText, UsageMonSettings:, UsageMonSetHotkey
        if (!UsageMonitorParseHotkeyText(hotkeyText, newHotkey, errorText))
        {
            UsageMonitorSettingsShowError(errorText)
            return
        }
        err := Func("UsageMonitorStandaloneApplyHotkey").Call(newHotkey)
        if (err != "")
        {
            UsageMonitorSettingsShowError(err)
            return
        }
    }

    prefOrder := ["off", "auto", "cli", "firefox"]
    codex := prefOrder[codexIndex], claude := prefOrder[claudeIndex], grok := prefOrder[grokIndex]
    providersChanged := UsageMonitorSettingsWriteIfChanged("Providers", "codex", codex, init.codex)
    providersChanged := UsageMonitorSettingsWriteIfChanged("Providers", "claude", claude, init.claude) || providersChanged
    providersChanged := UsageMonitorSettingsWriteIfChanged("Providers", "grok", grok, init.grok) || providersChanged
    ; settings.ini is shared by both hosts: a Save where the add-on row was not built (the
    ; standalone app) must leave the other host's add-on choice alone.
    if (usageMonitorAddonActive && addonIndex)
    {
        addon := (addonIndex = 2) ? "on" : "off"
        providersChanged := UsageMonitorSettingsWriteIfChanged("Providers", "addon", addon, init.addon) || providersChanged
    }

    profileChanged := false
    if (claude = "auto" || claude = "firefox")
    {
        profile := (profileIndex <= 1) ? "" : init.profileNames[profileIndex - 1]
        if (profile != init.profile)
        {
            usageMonitorClaudeProfile := profile
            UsageMonitorPersistClaudeProfile()
            profileChanged := true
        }
    }

    anchor := (anchorIndex = 2) ? "apps" : "screen"
    anchorChanged := UsageMonitorSettingsWriteIfChanged("Settings", "anchorMode", anchor, init.anchor)

    refresh := init.refreshValues[refreshIndex]
    refreshChanged := (refresh != "legacy") && UsageMonitorSettingsWriteIfChanged("Settings", "refreshSeconds", refresh, init.refresh)

    theme := (themeIndex = 2) ? "cyberpunk" : "default"
    themeChanged := false
    if (theme != init.theme)
    {
        usageMonitorTheme := theme
        UsageMonitorPersistTheme()
        themeChanged := true
    }

    UsageMonitorCloseSettings()
    UsageMonitorLoadProviderPrefs()
    if (anchorChanged)
        UsageMonitorReopenForAnchorChange()
    else if (themeChanged)
        UsageMonitorRebuildPopup()
    else if (providersChanged && usageMonitorVisible && usageMonitorGuiReady && IsObject(usageMonitorLastSnapshot))
        UsageMonitorApplySnapshot(usageMonitorLastSnapshot, usageMonitorLastSnapshotStatus)
    if (refreshChanged)
    {
        UsageMonitorLoadRefreshOverride()
        usageMonitorRefreshIdleStreak := 0
        if (!usageMonitorFetchInFlight)
            UsageMonitorScheduleAutoRefresh()
    }
    if (providersChanged || profileChanged)
        UsageMonitorRefreshAfterSettings()
}

; New provider or profile choices take effect with a fresh snapshot, now or right after the
; fetch already running.
UsageMonitorRefreshAfterSettings()
{
    global usageMonitorVisible, usageMonitorFetchInFlight, usageMonitorRefreshQueued

    if (!usageMonitorVisible)
        return
    if (usageMonitorFetchInFlight)
    {
        usageMonitorRefreshQueued := true
        return
    }
    UsageMonitorRequestRefresh()
}

UsageMonSettingsGuiClose:
UsageMonSettingsGuiEscape:
UsageMonSettingsBtnCancel:
    UsageMonitorCloseSettings()
return

UsageMonSettingsBtnSave:
    UsageMonitorSettingsSave()
return

UsageMonSettingsClaudeChanged:
    UsageMonitorSettingsSyncProfileRow()
return
