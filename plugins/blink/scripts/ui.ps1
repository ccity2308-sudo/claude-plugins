# Blink for Windows: a small resident helper that draws the notification card and plays the sound.
#   ui.ps1            run the helper (bell.sh starts it on demand; it exits by itself after 4 idle hours)
#   ui.ps1 settings   open the settings window
# bell.sh drops one key=value file per event (plus the raw hook JSON) into %LOCALAPPDATA%\blink\spool; the
# helper polls that folder every 40 ms, so the sound and the card appear together a moment after the agent asks.
# Settings live in %APPDATA%\blink\settings.conf (the same file bell.sh reads).
#   ui.ps1 snapshot DIR   render the settings pages and sample cards to PNG files (for the README and reviews)
#   ui.ps1 demo           play a scripted scene with four agents: agent bar, cards, answers (for videos and reviews)
param([string]$Mode = 'helper', [string]$Out = '')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$ErrorActionPreference = 'Continue'

$root  = Split-Path -Parent $PSScriptRoot
$state = Join-Path $env:LOCALAPPDATA 'blink'
$spool = Join-Path $state 'spool'
$conf  = Join-Path $env:APPDATA 'blink\settings.conf'
New-Item -ItemType Directory -Force $spool, (Split-Path $conf) | Out-Null

if ($Mode -eq 'helper') {
  $mutex = New-Object Threading.Mutex($false, 'Local\blink-helper')
  if (-not $mutex.WaitOne(0)) { exit }                                  # one helper per user
}
# Coming from agent-bell (the old name): drop its Start entry and keep its settings.
Remove-Item (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\agent-bell.lnk') -Force -ErrorAction SilentlyContinue
$old = Join-Path $env:APPDATA 'agent-bell\settings.conf'; if ((Test-Path $old) -and -not (Test-Path $conf)) { Copy-Item $old $conf }

# ---- settings file (key=value) -------------------------------------------------------------------------------
$DEFAULTS = [ordered]@{ 'claude.enabled' = '1'; 'claude.theme' = 'eyes'; 'claude.done_after' = '30'; 'claude.quick' = '1'; 'claude.quick_wait' = '20'
                        'claude.on_permission' = '1'; 'claude.on_question' = '1'; 'claude.custom_ask' = ''; 'claude.custom_done' = ''
                        'codex.custom_ask' = ''; 'codex.custom_done' = ''; 'link_target' = ''
                        'codex.enabled' = '1'; 'codex.theme' = 'glass'; 'codex.done_after' = '0'
                        'popup' = '1'; 'position' = 'top-right'; 'volume' = '70'
                        'card_ask' = '25'; 'card_done' = '8'; 'show_cmd' = '1'; 'quiet' = 'off'; 'mac.style' = 'notch'; 'dock' = '1'
                        'dock_pos' = 'top-center'; 'dock_x' = ''; 'dock_y' = ''; 'dock_size' = '100'; 'dock_alpha' = '100'; 'dock_round' = '18'; 'dock_bg' = 'black'
                        'dock_eyes' = '1'; 'dock_when' = 'always'; 'dock_open' = 'hover'; 'dock_lock' = '0'
                        'tray' = '1'; 'autostart' = '0'; 'anim' = '1'; 'anim_speed' = '100'; 'card_size' = '100'; 'card_alpha' = '100'; 'eye_ask' = '#FF7A12'; 'eye_work' = '#4DA3FF' }
function Read-Conf {
  $c = [ordered]@{}; foreach ($k in $DEFAULTS.Keys) { $c[$k] = $DEFAULTS[$k] }
  if (Test-Path $conf) { foreach ($l in [IO.File]::ReadAllLines($conf)) { if ($l -match '^\s*([\w.\-]+)=(.*)$') { $c[$Matches[1]] = $Matches[2].Trim() } } }
  $c
}
function Save-Conf($c) {
  $lines = @('# blink settings (written by the settings window; bell.sh reads it too)') + ($c.Keys | ForEach-Object { "$_=$($c[$_])" })
  [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
}

# ---- sound ---------------------------------------------------------------------------------------------------
$players = @{}
function Sound-Path($theme, $kind, $agent) {
  if ($theme -eq 'system') { if ($kind -eq 'done') { "$env:WINDIR\Media\Windows Notify Calendar.wav" } else { "$env:WINDIR\Media\Windows Notify System Generic.wav" } }
  elseif ($theme -eq 'custom') {                                           # the user's own files; "finished" falls back to the "needs you" one
    $c = Read-Conf; $p = $c["$agent.custom_$kind"]; if (-not $p) { $p = $c["$agent.custom_ask"] }; $p
  }
  else { Join-Path $root "assets\$($theme)_$kind.wav" }
}
function Play-Sound($theme, $kind, $volume, $agent = 'claude') {
  if (-not $theme -or $theme -eq 'off') { return }
  $path = Sound-Path $theme $kind $agent; if (-not $path -or -not (Test-Path $path)) { return }
  $p = $players[$path]
  if (-not $p) { $p = New-Object Windows.Media.MediaPlayer; $p.Open([Uri]$path); $players[$path] = $p }
  $p.Volume = [double]$volume / 100; $p.Position = [TimeSpan]::Zero; $p.Play()
}
function Preload($c) { foreach ($t in @($c['claude.theme'], $c['codex.theme'])) { foreach ($k in 'ask', 'done') {
  $path = Sound-Path $t $k 'claude'; if ($path -and (Test-Path $path) -and -not $players[$path]) { $p = New-Object Windows.Media.MediaPlayer; $p.Open([Uri]$path); $p.Volume = 0; $players[$path] = $p } } } }

# ---- what the agent wants, read from the raw hook JSON ---------------------------------------------------------
# Quick Allow is offered only when the card can show exactly what will run: a shell command (or a read-only tool's
# target) parsed by a real JSON parser, short enough to show whole, on one line, with no control characters.
# File edits and anything else get Deny / In terminal only, because the card cannot show the change itself.
$READ_ONLY = @{ Read = 'file_path'; Glob = 'pattern'; Grep = 'pattern'; WebFetch = 'url'; WebSearch = 'query'; LS = 'path' }
function Get-Detail($e) {
  $d = @{ text = $e.cmd; safe = $false; tool = '' }
  if ($e.demo) { $d.safe = $true; $d.tool = 'Bash'; return $d }
  if (-not ($e.raw -and (Test-Path $e.raw))) { return $d }
  try {
    $j = [IO.File]::ReadAllText($e.raw, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $d.tool = [string]$j.tool_name; $ti = $j.tool_input
    if ($d.tool -eq 'Bash' -and $ti.command) { $d.text = [string]$ti.command; $ok = $true }
    elseif ($READ_ONLY.ContainsKey($d.tool) -and $ti.($READ_ONLY[$d.tool])) { $d.text = "$($d.tool): " + [string]$ti.($READ_ONLY[$d.tool]); $ok = $true }
    elseif ($ti) { $d.text = "$($d.tool): " + ($ti | ConvertTo-Json -Compress -Depth 4); $ok = $false }
    # No control or invisible format characters (bidi overrides, zero-width marks, odd spaces) that could make the
    # card show something other than what runs.
    $d.safe = $ok -and $d.text.Length -le 600 -and $d.text -notmatch '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}   -   　]'
  } catch {} finally { Remove-Item $e.raw -Force -ErrorAction SilentlyContinue }
  $d
}

# ---- the card ------------------------------------------------------------------------------------------------
$OR = '#FF7A12'; $BLUE = '#4DA3FF'
$CARD_BORDER = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Card" Margin="14" CornerRadius="16" RenderTransformOrigin="0.5,0.5" Background="#F5161619" BorderBrush="#2C2C32" BorderThickness="1" Padding="14,14,12,14"
        Cursor="Hand" TextElement.FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border.RenderTransform><TransformGroup><ScaleTransform x:Name="Zoom"/><TranslateTransform x:Name="Slide"/></TransformGroup></Border.RenderTransform>
  <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="8" Direction="270" Opacity="0.55" Color="#000000"/></Border.Effect>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Rectangle x:Name="Accent" Width="3" RadiusX="1.5" RadiusY="1.5" HorizontalAlignment="Left" Margin="-9,3,0,3" RenderTransformOrigin="0.5,0"/>
    <Border Width="54" Height="54" CornerRadius="13" Background="#0C0C0E" BorderBrush="#25252A" BorderThickness="1" VerticalAlignment="Top">
      <Canvas Width="54" Height="54">
        <Rectangle x:Name="EyeL" Canvas.Left="11" Canvas.Top="24" Width="13" Height="6" RadiusX="2" RadiusY="2"/>
        <Rectangle x:Name="EyeR" Canvas.Left="30" Canvas.Top="24" Width="13" Height="6" RadiusX="2" RadiusY="2"/>
      </Canvas>
    </Border>
    <StackPanel Grid.Column="1" Margin="14,1,6,0">
      <DockPanel x:Name="AgentRow">
        <Ellipse x:Name="Dot" Width="8" Height="8" Margin="0,0,7,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Agent" FontFamily="Cascadia Mono, Consolas" FontSize="10.5" Foreground="#85847F" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <TextBlock x:Name="Session" FontSize="12.5" Foreground="#C9C7C1" TextTrimming="CharacterEllipsis" Margin="0,3,0,0" Visibility="Collapsed"/>
      <Grid Margin="0,3,0,0">
        <TextBlock x:Name="Title" FontSize="16" FontWeight="SemiBold" Foreground="#F2F1EE"/>
        <StackPanel x:Name="TitleFx" Orientation="Horizontal" ClipToBounds="True" Visibility="Collapsed"/>
      </Grid>
      <TextBlock x:Name="Msg" FontSize="13" Foreground="#B4B2AC" TextWrapping="Wrap" Margin="0,2,0,0"/>
      <Border x:Name="CmdBox" Visibility="Collapsed" Background="#0C0C0E" BorderBrush="#25252A" BorderThickness="1" CornerRadius="7" Padding="9,6" Margin="0,9,0,0">
        <ScrollViewer MaxHeight="132" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <TextBlock x:Name="Cmd" FontFamily="Cascadia Mono, Consolas" FontSize="12" Foreground="#E6E4DF" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Border>
      <TextBlock x:Name="Why" Visibility="Collapsed" FontSize="11.5" Foreground="#85847F" TextWrapping="Wrap" Margin="0,7,0,0"/>
      <StackPanel x:Name="Quick" Visibility="Collapsed" Margin="0,10,0,0">
        <WrapPanel>
          <Border x:Name="QAllow" CornerRadius="8" Background="#FF7A12" Padding="14,6" Margin="0,0,6,0" Cursor="Hand">
            <TextBlock Text="Allow" FontSize="13" FontWeight="SemiBold" Foreground="#111113"/></Border>
          <Border x:Name="QDeny" CornerRadius="8" Background="#1E1E22" BorderBrush="#34343A" BorderThickness="1" Padding="14,6" Margin="0,0,6,0" Cursor="Hand">
            <TextBlock Text="Deny" FontSize="13" Foreground="#F2F1EE"/></Border>
          <Border x:Name="QTerm" CornerRadius="8" Background="Transparent" Padding="10,6" Cursor="Hand">
            <TextBlock Text="In terminal" FontSize="13" Foreground="#85847F"/></Border>
        </WrapPanel>
        <Border Height="2" CornerRadius="1" Background="#26262B" Margin="0,10,0,0" HorizontalAlignment="Stretch">
          <Rectangle x:Name="Bar" Height="2" Fill="#FF7A12" HorizontalAlignment="Left" Width="0" RadiusX="1" RadiusY="1"/></Border>
      </StackPanel>
      <TextBlock x:Name="Answered" Visibility="Collapsed" FontSize="13" FontWeight="SemiBold" Margin="0,10,0,0"/>
    </StackPanel>
    <TextBlock x:Name="Close" Grid.Column="2" Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#6E6D69" Padding="6" VerticalAlignment="Top"/>
  </Grid>
</Border>
'@
$CARD_XAML = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" SizeToContent="Height" Width="420" Focusable="False" UseLayoutRounding="True">' + $CARD_BORDER + '</Window>'
$cards = New-Object Collections.ArrayList
function Brush($hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function Color($hex) { [Windows.Media.ColorConverter]::ConvertFromString($hex) }

function Fill-Card($el, $e, $c, $d) {   # $el: the card window or a bare card Border (the settings preview)
  $ask = $e.kind -eq 'ask'; $col = if ($ask) { $c['eye_ask'] } else { $c['eye_work'] }
  $tint = if ($e.color) { $e.color } else { $PALETTE[0] }                  # eyes keep the state colours, the agent's own colour marks the card
  $el.FindName('Dot').Fill = Brush $tint; $el.FindName('Accent').Fill = Brush $tint; $el.FindName('Bar').Fill = Brush $tint
  $label = if ($e.agent -eq 'codex') { 'CODEX' } else { 'CLAUDE CODE' }
  $dot = '  ' + [char]0x00B7 + '  '
  $el.FindName('Agent').Text = $label + $(if ($e.project) { $dot + $e.project.ToUpper() } else { '' })
  $sn = $el.FindName('Session'); if ($e.session) { $sn.Text = $e.session; $sn.Visibility = 'Visible' } else { $sn.Visibility = 'Collapsed' }
  $el.FindName('Title').Text = $e.title
  $el.FindName('Msg').Text = $e.msg
  $cb = $el.FindName('CmdBox')
  if ($ask -and $d.text -and $c['show_cmd'] -ne '0') { $el.FindName('Cmd').Text = $(if ($d.tool -eq 'Bash' -or -not $d.tool) { '$ ' } else { '' }) + $d.text; $cb.Visibility = 'Visible' }
  else { $cb.Visibility = 'Collapsed' }
  foreach ($n in 'EyeL', 'EyeR') {
    $r = $el.FindName($n); $r.Fill = Brush $col
    $fx = New-Object Windows.Media.Effects.DropShadowEffect; $fx.Color = Color $col; $fx.BlurRadius = 14; $fx.ShadowDepth = 0; $fx.Opacity = .95; $r.Effect = $fx
    $r.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $r.Opacity = 1
    if ($ask) {                                                            # waiting: the eyes breathe, like the pad's
      $a = New-Object Windows.Media.Animation.DoubleAnimation(1, .45, [TimeSpan]::FromMilliseconds(900)); $a.AutoReverse = $true
      $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever; $a.EasingFunction = New-Object Windows.Media.Animation.SineEase
      $r.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    }
  }
  $q = $el.FindName('Quick'); $why = $el.FindName('Why'); $el.FindName('Answered').Visibility = 'Collapsed'; $why.Visibility = 'Collapsed'
  if ($ask -and $e.reply) {
    $q.Visibility = 'Visible'
    $allow = $el.FindName('QAllow')
    if ($d.safe -and $c['show_cmd'] -ne '0') { $allow.Visibility = 'Visible' }
    else {
      $allow.Visibility = 'Collapsed'; $why.Visibility = 'Visible'
      $why.Text = if ($c['show_cmd'] -eq '0') { 'Allow is off while the command is hidden. Show commands in settings, or answer in the terminal.' }
                  else { 'This one is too long or not a plain command to approve from here. Check it in the terminal.' }
    }
  } else { $q.Visibility = 'Collapsed' }
}

function Card-Left($w, $c) {
  $wa = [Windows.SystemParameters]::WorkArea
  if ($c['position'] -like '*-center') { $wa.Left + ($wa.Width - $w.Width) / 2 } elseif ($c['position'] -like '*-left') { $wa.Left } else { $wa.Right - $w.Width }
}
function Layout-Cards($c) {
  # Top right by default: Windows (and the Claude app's own) notifications pile up bottom right and would cover the card.
  # 40 px down keeps window title-bar buttons clickable; "top-center" sits like an island at the top edge.
  $wa = [Windows.SystemParameters]::WorkArea; $top = $c['position'] -like 'top-*'
  $under = if ($script:DockWin -and $script:DockWin.IsVisible -and $c['dock_pos'] -eq $c['position']) { 34 * [double]$c['dock_size'] / 100 } else { 0 }   # never on top of the bar
  $y = if ($c['position'] -eq 'top-center') { $wa.Top + $under } elseif ($top) { $wa.Top + 40 + $under } else { $wa.Bottom - 4 - $under }
  foreach ($w in $cards) {
    $h = if ($w.ActualHeight -gt 0) { $w.ActualHeight } else { 120 }
    $w.Left = Card-Left $w $c; $w.Top = if ($top) { $y } else { $y - $h }
    if ($top) { $y += $h - 18 } else { $y -= $h - 18 }                     # the 14 px margins overlap: cards sit 10 px apart
  }
}
# ---- small animations -----------------------------------------------------------------------------------------
function Fade-In($el, $dy, $ms) {      # appear: fade in while sliding $dy px into place
  $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
  $tt = New-Object Windows.Media.TranslateTransform; $el.RenderTransform = $tt
  $a = New-Object Windows.Media.Animation.DoubleAnimation($dy, 0, [TimeSpan]::FromMilliseconds($ms)); $a.EasingFunction = $ease
  $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a)
  $el.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds($ms))))
}
function Blink-Eyes($el, $times) {     # the eyes close and open, like the pad saying it is done
  foreach ($n in 'EyeL', 'EyeR') {
    $r = $el.FindName($n); $r.RenderTransformOrigin = '0.5,0.5'; $st = New-Object Windows.Media.ScaleTransform; $r.RenderTransform = $st
    $k = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    for ($i = 0; $i -lt $times; $i++) { $t0 = 260 + $i * 320
      foreach ($f in @(@(0, 1), @(70, .08), @(150, 1))) { [void]$k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame($f[1], [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($t0 + $f[0]))))) } }
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $k)
  }
}
function Ease-Out { $x = New-Object Windows.Media.Animation.ExponentialEase; $x.EasingMode = 'EaseOut'; $x.Exponent = 4; $x }   # the site's expo.out
function Ms($v) { [TimeSpan]::FromMilliseconds($v) }
$script:AnimK = 1.0
function Anim($from, $to, $ms, $delay = 0, $ease = $null) {
  $a = New-Object Windows.Media.Animation.DoubleAnimation($from, $to, (Ms ($ms * $script:AnimK))); $a.BeginTime = Ms ($delay * $script:AnimK)
  if ($ease) { $a.EasingFunction = $ease }; $a
}
function AnimTo($to, $ms) {             # from wherever it is now: reversing halfway never jumps
  $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.To = $to; $a.Duration = New-Object Windows.Duration (Ms ($ms * $script:AnimK)); $a.EasingFunction = Ease-Out; $a
}
function Rise($el, $dy, $ms, $delay) {  # fade in while rising into place, after $delay ms
  $tt = New-Object Windows.Media.TranslateTransform; $tt.Y = $dy; $el.RenderTransform = $tt; $el.Opacity = 0
  $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim $dy 0 $ms $delay (Ease-Out)))
  $el.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0 1 ($ms * .55) $delay))
}
function Letters($w, $text, $delay) {   # the title comes up letter by letter from behind a mask, like the headlines on the site
  $fx = $w.FindName('TitleFx'); $fx.Children.Clear(); $w.FindName('Title').Visibility = 'Hidden'; $fx.Visibility = 'Visible'; $i = 0
  foreach ($ch in $text.ToCharArray()) {
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $(if ($ch -eq ' ') { [string][char]0xA0 } else { [string]$ch })
    $t.FontSize = 16; $t.FontWeight = 'SemiBold'; $t.Foreground = Brush '#F2F1EE'
    $tt = New-Object Windows.Media.TranslateTransform; $tt.Y = 24; $t.RenderTransform = $tt
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim 24 0 300 ($delay + $i * 11) (Ease-Out)))
    [void]$fx.Children.Add($t); $i++
  }
}
function Enter-Card($w, $e, $pos) {  # the card lands, its colour bar draws down, then the content comes up in order
  $center = $pos -like '*-center'; $zoom = $w.FindName('Zoom'); $slide = $w.FindName('Slide')
  foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $zoom.BeginAnimation($p, (Anim .95 1 260 0 (Ease-Out))) }
  $slide.BeginAnimation($(if ($center) { [Windows.Media.TranslateTransform]::YProperty } else { [Windows.Media.TranslateTransform]::XProperty }), (Anim $(if ($center) { -18 } elseif ($pos -like '*-left') { -36 } else { 36 }) 0 260 0 (Ease-Out)))
  $w.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0 1 130))
  $acc = $w.FindName('Accent'); $st = New-Object Windows.Media.ScaleTransform; $acc.RenderTransform = $st
  $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (Anim 0 1 340 30 (Ease-Out)))
  Letters $w $e.title 50
  $d = 30
  foreach ($n in 'AgentRow', 'Session', 'Msg', 'CmdBox', 'Why', 'Quick') {
    $el = $w.FindName($n); if ($el.Visibility -ne 'Visible') { continue }
    Rise $el 10 260 $d; $d += $(if ($n -eq 'Session') { 90 } else { 30 })
  }
}
function Press($el) {                   # buttons sink a little under the finger and spring back
  $el.RenderTransformOrigin = '0.5,0.5'; $el.RenderTransform = New-Object Windows.Media.ScaleTransform
  $el.Add_MouseEnter({ param($s) $s.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 1 .85 70)) })
  $el.Add_MouseLeave({ param($s) $s.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim .85 1 90))
    foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $s.RenderTransform.BeginAnimation($p, (Anim $s.RenderTransform.ScaleX 1 90)) } })
  $el.Add_PreviewMouseLeftButtonDown({ param($s) foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $s.RenderTransform.BeginAnimation($p, (Anim 1 .93 50)) } })
  $el.Add_PreviewMouseLeftButtonUp({ param($s) $b = New-Object Windows.Media.Animation.BackEase; $b.EasingMode = 'EaseOut'; $b.Amplitude = .6
    foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $s.RenderTransform.BeginAnimation($p, (Anim .93 1 170 0 $b)) } })
}
function Close-Card($w) {              # shrink and fade first; the timer comes back to really close it
  if (-not $cards.Contains($w)) { return }
  if (-not $w.Tag.closing) { $w.Tag.closing = $true; $w.Tag.until = [DateTime]::Now.AddMilliseconds(150 * $script:AnimK + 20)
    $in = New-Object Windows.Media.Animation.CubicEase; $in.EasingMode = 'EaseIn'
    $z = $w.FindName('Zoom'); foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $z.BeginAnimation($p, (Anim 1 .96 140 0 $in)) }
    $w.FindName('Slide').BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim 0 -6 140 0 $in))
    $w.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 1 0 140 0 $in)); return }
  [void]$cards.Remove($w); $w.Close(); Layout-Cards (Read-Conf)
}
function Show-Card($e, $c) {
  $d = Get-Detail $e
  if ($sessions.Contains($e.key)) { $sessions[$e.key].allow = [bool]($d.safe -and $e.reply -and $c['show_cmd'] -ne '0'); $sessions[$e.key].text = $d.text }
  $w = $null
  foreach ($x in $cards) { if ($x.Tag.key -eq $e.key) { $w = $x } }       # the same session updates its card instead of stacking
  $fresh = -not $w
  if ($fresh) { $w = [Windows.Markup.XamlReader]::Parse($CARD_XAML) }
  Fill-Card $w $e $c $d
  $ask = $e.kind -eq 'ask'
  $hold = if ($ask) { $c['card_ask'] } else { $c['card_done'] }
  $until = if ($hold -eq 'stay') { [DateTime]::MaxValue } else { [DateTime]::Now.AddSeconds([double]$hold) }
  $w.Tag = @{ key = $e.key; until = $until; reply = $e.reply }
  if ($ask -and $e.reply) {
    $min = [DateTime]::Now.AddSeconds([int]$e.wait + 1); if ($w.Tag.until -lt $min) { $w.Tag.until = $min }   # stay at least while it waits
    foreach ($b in @(@($w.FindName('QAllow'), 'allow'), @($w.FindName('QDeny'), 'deny'), @($w.FindName('QTerm'), 'terminal'))) { $b[0].Tag = $b[1] }
  }
  if ($fresh) {
    $w.FindName('Card').Add_MouseLeftButtonUp({ param($s, $ev) if (-not $ev.Handled) { Close-Card ([Windows.Window]::GetWindow($s)) } })
    foreach ($n in 'QAllow', 'QDeny', 'QTerm') { Press $w.FindName($n); $w.FindName($n).Add_MouseLeftButtonUp({ param($s, $ev) $ev.Handled = $true; Send-Reply ([Windows.Window]::GetWindow($s)) $s.Tag }) }
    $w.Add_MouseEnter({ param($s) if (-not $s.Tag.closing) { $s.Tag.until = [DateTime]::MaxValue } })
    $w.Add_MouseLeave({ param($s) if (-not $s.Tag.closing) { $s.Tag.until = [DateTime]::Now.AddSeconds(4) } })
    $k = [double]$c['card_size'] / 100; $w.Width = 420 * $k; $bd = $w.FindName('Card'); $bd.LayoutTransform = New-Object Windows.Media.ScaleTransform($k, $k); $bd.Opacity = [double]$c['card_alpha'] / 100
    $w.Opacity = 0
    [void]$cards.Insert(0, $w); $w.Show(); $w.UpdateLayout(); Layout-Cards $c
    Enter-Card $w $e $c['position']
  } else { $w.FindName('TitleFx').Visibility = 'Collapsed'; $w.FindName('Title').Visibility = 'Visible'; $w.UpdateLayout(); Layout-Cards $c }
  Blink-Eyes $w $(if ($ask) { 1 } else { 2 })
  if ($ask -and $e.reply) {                                                 # the thin bar runs out when the card stops waiting
    $bar = $w.FindName('Bar'); $full = $bar.Parent.ActualWidth
    $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-Object Windows.Media.Animation.DoubleAnimation($full, 0, [TimeSpan]::FromSeconds([int]$e.wait))))
  }
}
function Send-Reply($w, $answer) {
  $id = $w.Tag.reply; if (-not $id) { return }
  if ($answer -eq 'allow' -and $w.FindName('QAllow').Visibility -ne 'Visible') { return }   # never allow what the card did not show
  $dir = Join-Path $state 'replies'; New-Item -ItemType Directory -Force $dir | Out-Null
  if ($id -notlike 'test-*') { [IO.File]::WriteAllText((Join-Path $dir $id), $answer) }   # bell.sh is waiting for this file
  if ($sessions.Contains($w.Tag.key)) { $x = $sessions[$w.Tag.key]; $x.reply = ''; $x.allow = $false; if ($answer -ne 'terminal') { Set-State $x 'work' }; Update-Dock (Read-Conf) }
  $w.Tag.reply = $null; $w.FindName('Quick').Visibility = 'Collapsed'; $w.FindName('Why').Visibility = 'Collapsed'
  $a = $w.FindName('Answered'); $a.Visibility = 'Visible'
  switch ($answer) { 'allow' { $a.Text = 'Allowed'; $a.Foreground = Brush '#4CC38A' } 'deny' { $a.Text = 'Denied'; $a.Foreground = Brush '#FF6B5E' } default { $a.Text = 'Answer it in the terminal'; $a.Foreground = Brush '#85847F' } }
  foreach ($n in 'EyeL', 'EyeR') { $r = $w.FindName($n); $r.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $r.Opacity = 1; $r.Fill = Brush $script:EyeWork; $r.Effect.Color = Color $script:EyeWork }
  Blink-Eyes $w 1; Fade-In $a 6 220
  $w.Tag.until = [DateTime]::Now.AddSeconds(1.6)
}
# ---- agents: every running session, its colour and what it is doing ---------------------------------------------
# The eyes keep their meaning everywhere (blue works, orange needs you). The colour says WHO: it marks the card, the bar
# and the Mac notch. A new session takes the next free colour; a click on its dot pins another one to that project.
$PALETTE = '#B18CFF', '#4CC38A', '#FF6FAE', '#F5D04E', '#3FD0D4', '#FF8A70', '#9FB4C7', '#C8A27A'
$sessions = [ordered]@{}
function Color-Key($p) { 'color.' + $(if ($p) { $p -replace '[^\w.\-]', '_' } else { 'none' }) }
function Pick-Color($project, $c) {
  $pin = $c[(Color-Key $project)]; if ($pin) { return $pin }
  $used = @($sessions.Values | ForEach-Object { $_.color })
  foreach ($p in $PALETTE) { if ($used -notcontains $p) { return $p } }
  $PALETTE[$sessions.Count % $PALETTE.Count]
}
function Set-State($s, $state) { if ($s.state -ne $state) { $s.state = $state; $s.since = [DateTime]::Now } }
function Track($e, $c) {
  if ($e.kind -eq 'end') { if ($sessions.Contains($e.key)) { $sessions.Remove($e.key) }; return $null }
  $s = if ($sessions.Contains($e.key)) { $sessions[$e.key] } else { $null }
  if (-not $s) {
    $s = @{ key = $e.key; agent = $e.agent; project = $e.project; session = ''; color = (Pick-Color $e.project $c); state = 'work'; since = [DateTime]::Now; seen = [DateTime]::Now; reply = ''; allow = $false; text = ''; replyEnd = [DateTime]::MinValue; fresh = $true }
    $sessions[$e.key] = $s
  }
  if ($e.session) { $s.session = $e.session }; if ($e.project) { $s.project = $e.project }
  $s.seen = [DateTime]::Now
  switch ($e.kind) { 'ask' { Set-State $s 'ask' } 'work' { Set-State $s 'work' } default { Set-State $s 'done' } }
  $s.reply = [string]$e.reply; $s.allow = $false
  $s.replyEnd = if ($e.reply) { [DateTime]::Now.AddSeconds([int]$e.wait) } else { [DateTime]::MinValue }
  $s
}
function Prune {                         # a session that went quiet without saying goodbye drops off the bar
  $now = [DateTime]::Now; $gone = @()
  foreach ($s in $sessions.Values) { $idle = ($now - $s.seen).TotalMinutes
    if (($s.state -eq 'done' -and $idle -ge 30) -or $idle -ge 360) { $gone += $s.key } }
  foreach ($k in $gone) { $sessions.Remove($k) }
  if ($gone) { Update-Dock (Read-Conf) }
}
$DOCK_XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" Width="460" Height="560" Focusable="False" UseLayoutRounding="True">
  <Grid x:Name="Root"><Rectangle x:Name="Zone" Fill="#01000000" Visibility="Collapsed"/>
  <Border x:Name="Pill" Width="110" BorderBrush="#2C2C32" ClipToBounds="True" Cursor="Hand" TextElement.FontFamily="Segoe UI Variable Text, Segoe UI">
    <Border.RenderTransform><TranslateTransform x:Name="Drop"/></Border.RenderTransform>
    <StackPanel x:Name="Stack">
      <Grid x:Name="BarRow" Height="30" Background="Transparent">
        <StackPanel x:Name="Eyes" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="12,0,0,0">
          <Rectangle x:Name="EyeL" Width="11" Height="5" RadiusX="2" RadiusY="2" Margin="0,0,5,0"/>
          <Rectangle x:Name="EyeR" Width="11" Height="5" RadiusX="2" RadiusY="2"/>
        </StackPanel>
        <StackPanel x:Name="Dots" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0"/>
      </Grid>
      <StackPanel x:Name="List" MaxHeight="0" Margin="12,0,12,0"/>
    </StackPanel>
  </Border></Grid>
</Window>
'@
$script:DockWin = $null; $script:DockOpen = $false; $script:DockHide = [DateTime]::MaxValue; $script:DockFresh = $false; $script:DockDown = $null
function Dock-Width($n, $c) { $(if ($c['dock_eyes'] -ne '0') { 61 } else { 18 }) + [math]::Max(1, $n) * 15 }
function Dock-Size {                     # always from where it is now, so a quick in-and-out never jumps
  $c = $script:DC; $p = $script:DockWin.FindName('Pill'); $l = $script:DockWin.FindName('List')
  $open = $script:DockOpen -and $sessions.Count -gt 0
  $p.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (AnimTo $(if ($open) { 440 } else { Dock-Width $sessions.Count $c }) 200))
  $h = 0; if ($open) { $extra = 0; foreach ($x in $sessions.Values) { if ($x.state -eq 'ask' -and $x.allow -and $x.text) { $extra += 20 * [math]::Ceiling($x.text.Length / 38) + 6 } }; $h = $sessions.Count * 56 + 16 + $extra }
  $l.BeginAnimation([Windows.FrameworkElement]::MaxHeightProperty, (AnimTo $h 200))
  # The bar is still growing while the mouse runs for its far end: the zone is already full size, so that run never counts as leaving.
  $z = $script:DockWin.FindName('Zone')
  if ($open) { $z.Width = 456; $z.Height = 30 + $h + 14; $z.Visibility = 'Visible' } else { $z.Visibility = 'Collapsed' }
}
function Dock-Spots {                    # where the bar's middle and top edge sit in each of the six places
  $wa = [Windows.SystemParameters]::WorkArea; $k = [double]$script:DC['dock_size'] / 100; $h = 30 * $k; $m = 10
  $o = [ordered]@{}; foreach ($v in 'top', 'bottom') { foreach ($u in 'left', 'center', 'right') {
    $edge = if ($u -eq 'center') { 0 } else { $m }
    $o["$v-$u"] = @{ y = $(if ($v -eq 'top') { $wa.Top + $edge } else { $wa.Bottom - $h - $edge }) ; x = $(switch ($u) { 'left' { $wa.Left + $m } 'center' { $wa.Left + $wa.Width / 2 } default { $wa.Right - $m } }) } } }
  $o
}
function Dock-Place($c) {                # applies every look-and-place setting without rebuilding anything
  $w = $script:DockWin; if (-not $w) { return }
  $k = [double]$c['dock_size'] / 100; $w.Width = 460 * $k; $w.Height = 560 * $k
  $p = $w.FindName('Pill'); $sc = New-Object Windows.Media.ScaleTransform($k, $k); $p.LayoutTransform = $sc; $z = $w.FindName('Zone'); $z.LayoutTransform = $sc; $p.Opacity = [double]$c['dock_alpha'] / 100
  $p.Background = Brush $(switch ($c['dock_bg']) { 'graphite' { '#F61E1E22' } 'glass' { '#A8141418' } default { '#F60A0A0C' } })
  $w.FindName('Eyes').Visibility = $(if ($c['dock_eyes'] -ne '0') { 'Visible' } else { 'Collapsed' })
  $r = [double]$c['dock_round']; $pos = $c['dock_pos']; $wa = [Windows.SystemParameters]::WorkArea
  if ($pos -eq 'free') {
    $x = [double]$c['dock_x']; $y = [double]$c['dock_y']; $down = $y -lt $wa.Top + $wa.Height / 2
    $p.HorizontalAlignment = 'Center'; $p.VerticalAlignment = $(if ($down) { 'Top' } else { 'Bottom' })
    $w.Left = $x - $w.Width / 2; $w.Top = $(if ($down) { $y } else { $y + 30 * $k - $w.Height })
    $p.CornerRadius = New-Object Windows.CornerRadius $r; $p.BorderThickness = 1
  } else {
    $sp = (Dock-Spots)[$pos]; $down = $pos -like 'top-*'; $hor = $pos.Split('-')[1]
    $p.HorizontalAlignment = @{ left = 'Left'; center = 'Center'; right = 'Right' }[$hor]; $p.VerticalAlignment = $(if ($down) { 'Top' } else { 'Bottom' })
    $w.Left = switch ($hor) { 'left' { $sp.x } 'center' { $sp.x - $w.Width / 2 } default { $sp.x - $w.Width } }
    $w.Top = $(if ($down) { $sp.y } else { $sp.y + 30 * $k - $w.Height })
    if ($hor -eq 'center') {             # in the middle it hangs off the screen edge, like a notch
      $p.CornerRadius = $(if ($down) { New-Object Windows.CornerRadius 0, 0, $r, $r } else { New-Object Windows.CornerRadius $r, $r, 0, 0 })
      $p.BorderThickness = $(if ($down) { New-Object Windows.Thickness 1, 0, 1, 1 } else { New-Object Windows.Thickness 1, 1, 1, 0 })
    } else { $p.CornerRadius = New-Object Windows.CornerRadius $r; $p.BorderThickness = 1 }
  }
  $z.HorizontalAlignment = $p.HorizontalAlignment; $z.VerticalAlignment = $p.VerticalAlignment
  $st = $w.FindName('Stack'); $bar = $w.FindName('BarRow'); $first = $st.Children[0] -eq $bar   # opening upwards: the list goes above the bar
  if ($first -ne $down) { $st.Children.Remove($bar); if ($down) { [void]$st.Children.Insert(0, $bar) } else { [void]$st.Children.Add($bar) } }
}
function Dock-Drop {                     # after a drag: snap to a spot when close to one, else stay exactly there
  $w = $script:DockWin; $p = $w.FindName('Pill'); $c = Read-Conf; $script:DC = $c; $k = [double]$c['dock_size'] / 100
  $pt = $p.TranslatePoint((New-Object Windows.Point(0, 0)), $w); $bar = $w.FindName('BarRow').TranslatePoint((New-Object Windows.Point(0, 0)), $w)
  $cx = $w.Left + $pt.X + $p.ActualWidth * $k / 2; $y = $w.Top + $bar.Y; $spots = Dock-Spots; $hit = $null
  foreach ($n in $spots.Keys) { $ax = $spots[$n].x; if ($n -like '*-left') { $ax += $p.ActualWidth * $k / 2 } elseif ($n -like '*-right') { $ax -= $p.ActualWidth * $k / 2 }
    if ([math]::Abs($cx - $ax) -lt 110 -and [math]::Abs($y - $spots[$n].y) -lt 60) { $hit = $n } }
  if ($hit) { $c['dock_pos'] = $hit } else { $c['dock_pos'] = 'free'; $c['dock_x'] = [string][int]$cx; $c['dock_y'] = [string][int]$y }
  Save-Conf $c; $script:DC = $c; $script:ConfAt = [IO.File]::GetLastWriteTimeUtc($conf); Dock-Place $c; Layout-Cards $c
  if ($script:C) { $script:C = $c; if ($script:Tab -eq 'agents') { Render-Page } }
}
function Ago($t) { $m = [int]([DateTime]::Now - $t).TotalMinutes; if ($m -lt 1) { 'now' } elseif ($m -lt 60) { "$m min" } else { '{0} h' -f [math]::Floor($m / 60) } }
function Dock-Rows {
  $list = $script:DockWin.FindName('List'); $list.Children.Clear(); $i = 0
  foreach ($s in $sessions.Values) {
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = 11; $b.Padding = '12,8'; $b.Background = Brush $(if ($s.state -eq 'ask') { '#26FF7A12' } else { '#16161A' })
    $down = $script:DockWin.FindName('Pill').VerticalAlignment -eq 'Top'; $last = $i -eq $sessions.Count - 1   # the outer gap matches the sides, whichever way the list opens
    $b.Margin = $(if ($down) { if ($last) { '0,0,0,12' } else { '0,0,0,4' } } else { if ($i -eq 0) { '0,12,0,4' } else { '0,0,0,4' } })
    $g = New-Object Windows.Controls.Grid
    foreach ($wd in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; [void]$g.ColumnDefinitions.Add($cd) }
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 11; $dot.Height = 11; $dot.Fill = Brush $s.color; $dot.Margin = '0,0,10,0'; $dot.Cursor = 'Hand'; $dot.Tag = $s.key; $dot.ToolTip = 'Change colour'
    $dot.Add_MouseLeftButtonUp({ param($x) Next-Color $x.Tag }); [void]$g.Children.Add($dot)
    $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($sp, 1)
    $name = if ($s.session) { $s.session } elseif ($s.project) { $s.project } else { $s.agent }
    $t1 = T $name 13 '#F2F1EE' 'SemiBold'; $t1.TextWrapping = 'NoWrap'; $t1.TextTrimming = 'CharacterEllipsis'; [void]$sp.Children.Add($t1)
    $who = if ($s.agent -eq 'codex') { 'Codex' } else { 'Claude Code' }
    $what = switch ($s.state) { 'ask' { 'needs you' } 'work' { 'working' } default { 'finished' } }
    $dotc = [string][char]0xB7
    $t2 = T "$who $dotc $(if ($s.project) { "$($s.project) $dotc " })$what $dotc $(Ago $s.since)" 11 $(if ($s.state -eq 'ask') { '#FF9A4D' } else { '#85847F' }); $t2.TextWrapping = 'NoWrap'; $t2.TextTrimming = 'CharacterEllipsis'; [void]$sp.Children.Add($t2)
    if ($s.state -eq 'ask' -and $s.allow -and $s.text) { $t3 = T ('$ ' + $s.text) 11.5 '#E6E4DF'; $t3.FontFamily = 'Cascadia Mono, Consolas'; $t3.Margin = '0,4,0,0'; [void]$sp.Children.Add($t3) }   # Allow here only with the whole command in view
    [void]$g.Children.Add($sp)
    if ($s.state -eq 'ask' -and $s.reply -and [DateTime]::Now -lt $s.replyEnd) {   # the same answers as on the card, and Allow only where the card offers it
      $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.Margin = '10,0,0,0'; $btns.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($btns, 2)
      foreach ($q in @(@('allow', 'Allow', '#FF7A12', '#111113'), @('deny', 'Deny', '#1E1E22', '#F2F1EE'))) {
        if ($q[0] -eq 'allow' -and -not $s.allow) { continue }
        $qb = New-Object Windows.Controls.Border; $qb.CornerRadius = 7; $qb.Background = Brush $q[2]; $qb.Padding = '11,4'; $qb.Margin = '4,0,0,0'; $qb.Cursor = 'Hand'; $qb.Tag = @{ key = $s.key; answer = $q[0] }
        $qt = T $q[1] 12 $q[3] 'SemiBold'; $qb.Child = $qt; Press $qb
        $qb.Add_MouseLeftButtonUp({ param($x) $k = $x.Tag.key; $an = $x.Tag.answer; foreach ($w in @($cards)) { if ($w.Tag.key -eq $k) { Send-Reply $w $an } } })
        [void]$btns.Children.Add($qb)
      }
      [void]$g.Children.Add($btns)
    }
    $b.Child = $g; [void]$list.Children.Add($b)
    $i++
  }
}
function Next-Color($key) {
  $s = $sessions[$key]; if (-not $s) { return }
  $i = [array]::IndexOf($PALETTE, $s.color); $s.color = $PALETTE[($i + 1) % $PALETTE.Count]
  $c = Read-Conf; $c[(Color-Key $s.project)] = $s.color; Save-Conf $c; Update-Dock $c
}
function Dock-Dots {
  $d = $script:DockWin.FindName('Dots'); $d.Children.Clear(); $ask = $false
  foreach ($s in $sessions.Values) {
    $e = New-Object Windows.Shapes.Ellipse; $e.Width = 9; $e.Height = 9; $e.Margin = '3,0,3,0'; $e.Fill = Brush $s.color; $e.RenderTransformOrigin = '0.5,0.5'
    if ($s.state -eq 'done') { $e.Opacity = .35 }
    if ($s.state -eq 'ask') { $ask = $true                                   # whoever needs you breathes, like the eyes
      $a = Anim 1 .35 800 0 (New-Object Windows.Media.Animation.SineEase); $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
      $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $a) }
    if ($s.fresh) { $s.fresh = $false; $st = New-Object Windows.Media.ScaleTransform; $e.RenderTransform = $st   # a new agent pops in
      $bk = New-Object Windows.Media.Animation.BackEase; $bk.EasingMode = 'EaseOut'; $bk.Amplitude = 1.2
      foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $st.BeginAnimation($p, (Anim 0 1 380 120 $bk)) } }
    [void]$d.Children.Add($e)
  }
  $col = if ($ask) { $script:DC['eye_ask'] } else { $script:DC['eye_work'] }
  foreach ($n in 'EyeL', 'EyeR') { $r = $script:DockWin.FindName($n); $r.Fill = Brush $col
    $fx = New-Object Windows.Media.Effects.DropShadowEffect; $fx.Color = Color $col; $fx.BlurRadius = 9; $fx.ShadowDepth = 0; $fx.Opacity = .9; $r.Effect = $fx }
}
function Dock-Open($on) {
  if ($script:DockOpen -eq $on -or -not $script:DockWin) { return }
  $script:DockOpen = $on; Dock-Size
  if ($on) { $i = 0; foreach ($b in $script:DockWin.FindName('List').Children) { Rise $b 8 200 ($i * 18); $i++ } }
}
function Update-Dock($c) {
  $script:DC = $c
  $show = $sessions.Count -gt 0 -and ($c['dock_when'] -ne 'ask' -or @($sessions.Values | Where-Object { $_.state -eq 'ask' }).Count -gt 0)
  if ($c['dock'] -eq '0' -or $c['popup'] -eq '0') { if ($script:DockWin) { $script:DockWin.Close(); $script:DockWin = $null }; return }
  if (-not $script:DockWin) {
    if (-not $show) { return }
    $w = [Windows.Markup.XamlReader]::Parse($DOCK_XAML); $script:DockWin = $w; $script:DockOpen = $false
    Dock-Place $c
    $p = $w.FindName('Pill'); $p.Width = Dock-Width $sessions.Count $c
    $root = $w.FindName('Root')
    $root.Add_MouseEnter({ if ($script:DC['dock_open'] -eq 'hover') { Dock-Open $true } })
    $root.Add_MouseLeave({ if ($script:DC['dock_open'] -eq 'hover') { Dock-Open $false } })
    $bar = $w.FindName('BarRow')
    $bar.Add_MouseLeftButtonDown({ param($s, $ev) $script:DockDown = $ev.GetPosition($script:DockWin) })
    $bar.Add_MouseMove({ param($s, $ev)      # hold the bar and drag it anywhere
      if ($script:DockDown -and $ev.LeftButton -eq 'Pressed' -and $script:DC['dock_lock'] -ne '1') {
        $q = $ev.GetPosition($script:DockWin); if ([math]::Abs($q.X - $script:DockDown.X) + [math]::Abs($q.Y - $script:DockDown.Y) -gt 5) {
          $script:DockDown = $null; Dock-Open $false; try { $script:DockWin.DragMove() } catch {}; Dock-Drop } } })
    $bar.Add_MouseLeftButtonUp({ if ($script:DockDown) { $script:DockDown = $null; if ($script:DC['dock_open'] -eq 'click') { Dock-Open (-not $script:DockOpen) } } })
    $w.Show()
    $from = $(if ($p.VerticalAlignment -eq 'Top') { -34 } else { 34 })
    $w.FindName('Drop').BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim $from 0 260 0 (Ease-Out)))
    Layout-Cards $c
  }
  Tray-Text; Dock-Dots; Dock-Rows; Dock-Size
  if (-not $show) { Dock-Open $false; $dir = $(if ($script:DockWin.FindName('Pill').VerticalAlignment -eq 'Top') { -34 } else { 34 })
    $script:DockWin.FindName('Drop').BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim 0 $dir 160)); $script:DockHide = [DateTime]::Now.AddMilliseconds(180 * $script:AnimK) }
  else { $script:DockHide = [DateTime]::MaxValue }
}
# ---- the icon by the clock -----------------------------------------------------------------------------------------
$script:Tray = $null
function Open-Blink { Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $PSScriptRoot 'open-settings.vbs') + '"') }
function Tray-Sync($c) {
  if ($Mode -ne 'helper') { return }
  if ($c['tray'] -eq '0') { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }; return }
  if ($script:Tray) { return }
  $t = New-Object Windows.Forms.NotifyIcon; $t.Text = 'Blink'
  $t.Icon = New-Object Drawing.Icon (Join-Path $root 'assets\icon.ico')
  $m = New-Object Windows.Forms.ContextMenuStrip
  [void]$m.Items.Add('Settings', $null, [EventHandler] { Open-Blink })
  $bar = New-Object Windows.Forms.ToolStripMenuItem 'Agent bar'; $bar.Add_Click({ $c = Read-Conf; $c['dock'] = $(if ($c['dock'] -eq '0') { '1' } else { '0' }); Save-Conf $c }); [void]$m.Items.Add($bar)
  $mute = New-Object Windows.Forms.ToolStripMenuItem 'Sound'; $mute.Add_Click({ $c = Read-Conf; $c['muted'] = $(if ($c['muted'] -eq '1') { '0' } else { '1' }); Save-Conf $c }); [void]$m.Items.Add($mute)
  [void]$m.Items.Add('-')
  [void]$m.Items.Add('Quit Blink', $null, [EventHandler] { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
  $m.Add_Opening({ $c = Read-Conf; $script:TrayBar.Checked = $c['dock'] -ne '0'; $script:TrayMute.Checked = $c['muted'] -ne '1' })
  $script:TrayBar = $bar; $script:TrayMute = $mute; $t.ContextMenuStrip = $m
  $t.Add_MouseClick({ param($s, $ev) if ($ev.Button -eq 'Left') { Open-Blink } })
  $t.Visible = $true; $script:Tray = $t
}
function Tray-Text {                     # hover the icon: who is running, who is waiting
  if (-not $script:Tray) { return }
  $n = $sessions.Count; $a = @($sessions.Values | Where-Object { $_.state -eq 'ask' }).Count
  $script:Tray.Text = if ($n -eq 0) { 'Blink' } elseif ($a) { "Blink: $a of $n need you" } else { "Blink: $n running" }
}
function Autostart-Sync($c) {            # a shortcut in the Startup folder, only when the switch is on
  if ($Mode -eq 'demo' -or $Mode -eq 'snapshot') { return }
  $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Blink.lnk'
  if ($c['autostart'] -eq '1') {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $s.Arguments = '"' + (Join-Path $PSScriptRoot 'start-helper.vbs') + '"'; $s.IconLocation = Join-Path $root 'assets\icon.ico'; $s.Description = 'Blink'; $s.Save()
  } elseif (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
}
function Conf-Changed($c) {              # every setting takes effect at once, also in the running helper
  Tray-Sync $c; Autostart-Sync $c
  $script:AnimK = if ($c['anim'] -eq '0') { 0.01 } else { 100 / [double]$c['anim_speed'] }
  $script:EyeWork = $c['eye_work']; $script:DC = $c
  if ($script:DockWin) { Dock-Place $c; Update-Dock $c } elseif ($sessions.Count) { Update-Dock $c }
  if ($cards.Count) { Layout-Cards $c }
}
$script:DC = Read-Conf; $script:EyeWork = $script:DC['eye_work']; $script:ConfAt = [DateTime]::MinValue
function Handle($e) {
  $c = Read-Conf
  $s = Track $e $c; if ($s) { $e.color = $s.color }
  if ($e.kind -in 'work', 'idle', 'end') {  # status only: no sound, no card. An answer given in the terminal clears the waiting card.
    if ($e.kind -ne 'idle') { foreach ($w in @($cards)) { if ($w.Tag.key -eq $e.key -and $w.Tag.reply) { Close-Card $w } } }
    Update-Dock $c; return
  }
  if ($c['muted'] -ne '1') { Play-Sound $e.theme $e.kind $c['volume'] $e.agent }  # sound first: the card's slide-in lands on the note
  if ($e.popup -ne '0' -and $c['popup'] -ne '0') { Show-Card $e $c } elseif ($e.raw) { Remove-Item $e.raw -Force -ErrorAction SilentlyContinue }
  Update-Dock $c
}
function Read-Event($f) {
  $e = @{}; foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) { $i = $l.IndexOf('='); if ($i -gt 0) { $e[$l.Substring(0, $i)] = $l.Substring($i + 1) } }; $e
}

# ---- settings window -----------------------------------------------------------------------------------------
# Three columns: sections on the left, the controls in the middle, a live preview of the card on the right.
$SET_XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Blink settings" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Width="1080" Height="700" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
        <Border x:Name="T" Width="42" Height="24" CornerRadius="12" Background="#2C2C32">
          <Ellipse x:Name="K" Width="18" Height="18" Margin="3" Fill="#9A9893" HorizontalAlignment="Left"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="T" Property="Background" Value="#FF7A12"/>
            <Setter TargetName="K" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="K" Property="Fill" Value="#FFFFFF"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="TrackOn" TargetType="RepeatButton"><Setter Property="Focusable" Value="False"/><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="RepeatButton"><Border Height="4" CornerRadius="2" Background="#FF7A12"/></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="TrackOff" TargetType="RepeatButton"><Setter Property="Focusable" Value="False"/><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="RepeatButton"><Border Height="4" CornerRadius="2" Background="#2C2C32"/></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="Knob" TargetType="Thumb"><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="Thumb"><Ellipse Width="18" Height="18" Fill="#F2F1EE" Cursor="Hand">
        <Ellipse.Effect><DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.5"/></Ellipse.Effect></Ellipse></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="Range" TargetType="Slider">
      <Setter Property="IsMoveToPointEnabled" Value="True"/><Setter Property="IsSnapToTickEnabled" Value="True"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
        <Grid Height="22"><Track x:Name="PART_Track">
          <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource TrackOn}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
          <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource TrackOff}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
          <Track.Thumb><Thumb Style="{StaticResource Knob}"/></Track.Thumb></Track></Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#F2F1EE"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" CornerRadius="9" Background="#1E1E22" BorderBrush="#34343A" BorderThickness="1" Padding="13,8"><ContentPresenter HorizontalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#8A8984"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Cta" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="#111113"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" CornerRadius="10" Background="#FF7A12" Padding="18,10"><ContentPresenter HorizontalAlignment="Center" TextElement.FontWeight="SemiBold" TextElement.FontSize="14"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#FF8F3A"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Margin="16" CornerRadius="18" Background="#141417" BorderBrush="#2C2C32" BorderThickness="1" ClipToBounds="True">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="10" Direction="270" Opacity="0.5" Color="#000000"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/><ColumnDefinition Width="372"/></Grid.ColumnDefinitions>
      <!-- sections -->
      <Border Background="#101012" CornerRadius="18,0,0,18" BorderBrush="#222227" BorderThickness="0,0,1,0">
        <DockPanel Margin="16,20,16,18">
          <StackPanel x:Name="Head" DockPanel.Dock="Top" Orientation="Horizontal" Background="Transparent" Margin="4,0,0,22">
            <Border Width="36" Height="36" CornerRadius="9" Background="#0A0A0C" BorderBrush="#25252A" BorderThickness="1">
              <Canvas Width="36" Height="36">
                <Rectangle Canvas.Left="7" Canvas.Top="15" Width="9" Height="5" RadiusX="2" RadiusY="2" Fill="#FF7A12"><Rectangle.Effect><DropShadowEffect BlurRadius="9" ShadowDepth="0" Color="#FF7A12"/></Rectangle.Effect></Rectangle>
                <Rectangle Canvas.Left="20" Canvas.Top="15" Width="9" Height="5" RadiusX="2" RadiusY="2" Fill="#FF7A12"><Rectangle.Effect><DropShadowEffect BlurRadius="9" ShadowDepth="0" Color="#FF7A12"/></Rectangle.Effect></Rectangle>
              </Canvas>
            </Border>
            <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Blink" FontSize="16" FontWeight="SemiBold" Foreground="#F2F1EE"/>
              <TextBlock x:Name="Ver" FontSize="11" Foreground="#6E6D69"/>
            </StackPanel>
          </StackPanel>
          <Border x:Name="Promo" DockPanel.Dock="Bottom" CornerRadius="12" Background="#18181C" BorderBrush="#26262B" BorderThickness="1" Padding="12" Cursor="Hand">
            <StackPanel>
              <Image x:Name="PromoImg" Height="76" Stretch="Uniform" Margin="0,0,0,8"/>
              <TextBlock Text="Answer with real keys" FontSize="12.5" FontWeight="SemiBold" Foreground="#F2F1EE"/>
              <TextBlock Text="getncloud.com  &#x2192;" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="#FF7A12" Margin="0,3,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="Nav"/>
        </DockPanel>
      </Border>
      <!-- controls -->
      <DockPanel Grid.Column="1">
        <Grid x:Name="Drag" DockPanel.Dock="Top" Background="Transparent" Height="20"/>
        <TextBlock x:Name="Saved" DockPanel.Dock="Bottom" Text="Changes are saved as you go." FontSize="11.5" Foreground="#6E6D69" Margin="30,0,0,16"/>
        <ScrollViewer VerticalScrollBarVisibility="Hidden" Margin="0,0,0,6"><StackPanel x:Name="Page" Margin="30,4,30,10"/></ScrollViewer>
      </DockPanel>
      <!-- preview -->
      <Border Grid.Column="2" Background="#0E0E10" CornerRadius="0,18,18,0" BorderBrush="#222227" BorderThickness="1,0,0,0">
        <DockPanel Margin="22,14,22,20">
          <Grid DockPanel.Dock="Top">
            <TextBlock Text="PREVIEW" FontFamily="Cascadia Mono, Consolas" FontSize="10.5" Foreground="#6E6D69" VerticalAlignment="Center"/>
            <TextBlock x:Name="X" Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="#85847F" HorizontalAlignment="Right" Padding="8" Cursor="Hand"/>
          </Grid>
          <StackPanel DockPanel.Dock="Bottom">
            <TextBlock x:Name="PrevNote" FontSize="11.5" Foreground="#6E6D69" TextWrapping="Wrap" Margin="2,0,0,12"/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="TryAsk" Style="{StaticResource Btn}" Content="Show it for real"/>
              <Button x:Name="TryDone" Style="{StaticResource Btn}" Content="Finished one"/>
            </StackPanel>
          </StackPanel>
          <StackPanel>
            <StackPanel x:Name="PrevKinds" Orientation="Horizontal" Margin="0,14,0,2"/>
            <ContentControl x:Name="PrevHost" Margin="-20,0,-20,0"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@
$SITE = 'https://getncloud.com/?utm_source=blink&utm_medium=settings'
function Open-Url($u) { Start-Process $u }
function Save-Now { Save-Conf $script:C; $script:Win.FindName('Saved').Text = 'Saved.'; Conf-Changed $script:C; Update-Preview }

# Small builders. No closures: every handler reads what it needs from the control's Tag and from $script: state.
function T($text, $size, $hex, $weight) { $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = $size; $t.Foreground = Brush $hex; if ($weight) { $t.FontWeight = $weight }; $t.TextWrapping = 'Wrap'; $t }
function Add($el) { [void]$script:Page.Children.Add($el) }
function H1($text, $sub) { $h = T $text 20 '#F2F1EE' 'SemiBold'; $h.Margin = '0,6,0,2'; Add $h; if ($sub) { $s = T $sub 12.5 '#85847F'; $s.Margin = '0,0,0,10'; Add $s } }
function Group($text) { $g = T $text.ToUpper() 10.5 '#6E6D69'; $g.FontFamily = 'Cascadia Mono, Consolas'; $g.Margin = '2,12,0,5'; Add $g }
function Row($title, $hint, $control) {
  # One setting. Switches and pickers sit on the right of the text; a slider goes full width under it, with its
  # value next to the title, so the text never gets squeezed into a narrow column.
  $b = New-Object Windows.Controls.Border; $b.Background = Brush '#18181C'; $b.CornerRadius = 11; $b.Padding = '14,10'; $b.Margin = '0,0,0,5'
  $g = New-Object Windows.Controls.Grid
  $c1 = New-Object Windows.Controls.ColumnDefinition; $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
  [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
  $slider = $control -is [Windows.Controls.Slider]
  $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; $sp.Margin = $(if ($slider) { '0' } else { '0,0,14,0' })
  [void]$sp.Children.Add((T $title 13.5 '#F2F1EE')); if ($hint) { $h = T $hint 11.5 '#85847F'; $h.Margin = '0,2,0,0'; [void]$sp.Children.Add($h) }
  [void]$g.Children.Add($sp)
  if ($slider) {
    $lab = $control.Tag.lab; $lab.VerticalAlignment = 'Top'; $lab.Margin = '12,0,0,0'; [Windows.Controls.Grid]::SetColumn($lab, 1); [void]$g.Children.Add($lab)
    $r2 = New-Object Windows.Controls.RowDefinition; $r2.Height = 'Auto'; [void]$g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition)); [void]$g.RowDefinitions.Add($r2)
    $control.Margin = '0,8,0,0'; [Windows.Controls.Grid]::SetRow($control, 1); [Windows.Controls.Grid]::SetColumnSpan($control, 2); [void]$g.Children.Add($control)
  } else { [Windows.Controls.Grid]::SetColumn($control, 1); [void]$g.Children.Add($control) }
  $b.Child = $g; Add $b; $b
}
function Switch($key, $on, $off) {   # writes $on / $off to $key
  $s = New-Object Windows.Controls.Primitives.ToggleButton; $s.Style = $script:Win.Resources['Switch']
  $s.Tag = @{ key = $key; on = $on; off = $off }
  $s.IsChecked = if ($on -is [scriptblock]) { $script:C[$key] -ne $off } else { $script:C[$key] -eq $on }   # a scriptblock "on" means any value but $off
  $s.Add_Click({ param($x) if ($x.IsChecked) { $v = $x.Tag.on; if ($v -is [scriptblock]) { $v = & $v } } else { $v = $x.Tag.off }; $script:C[$x.Tag.key] = [string]$v; Save-Now; Render-Page })
  $s
}
function Range($key, $min, $max, $step, $fmt, $value) {   # a slider; Row prints its value next to the title
  $sl = New-Object Windows.Controls.Slider; $sl.Style = $script:Win.Resources['Range']
  $sl.Minimum = $min; $sl.Maximum = $max; $sl.TickFrequency = $step; $sl.SmallChange = $step; $sl.LargeChange = $step
  $sl.Value = [double]$(if ($value -ne $null) { $value } else { $script:C[$key] })
  $lab = T '' 13.5 '#FF7A12' 'SemiBold'; $lab.TextWrapping = 'NoWrap'; $lab.TextAlignment = 'Right'
  $sl.Tag = @{ key = $key; fmt = $fmt; lab = $lab }; $lab.Text = (& $fmt $sl.Value)
  $sl.Add_ValueChanged({ param($x) $x.Tag.lab.Text = (& $x.Tag.fmt $x.Value); if ($x.Tag.key) { $script:C[$x.Tag.key] = [string][int]$x.Value; Save-Now } })
  @{ panel = $sl; slider = $sl }
}
function Secs($v) { $v = [int]$v; if ($v -ge 60) { '{0}:{1:00} min' -f [math]::Floor($v / 60), ($v % 60) } else { "$v s" } }

function Sound-Picker($agent) {
  # Plain names people recognise; the ids stay the same in the settings file.
  $THEMES = @(@('eyes', 'Marimba', 'Warm two-note chime. The n.cloud sound.'), @('glass', 'Soft tones', 'Two quiet, clean notes. The calmest one.'),
              @('bell', 'Desk bell', 'A small bell. You hear it from the next room.'), @('system', 'Windows sounds', 'Your usual Windows notification sounds.'),
              @('custom', 'My own sound', 'Pick any .wav or .mp3 file from your computer.'), @('off', 'No sound', 'Just the card.'))
  foreach ($t in $THEMES) {
    $sel = $script:C["$agent.theme"] -eq $t[0]
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = 11; $b.Padding = '13,9'; $b.Margin = '0,0,0,5'; $b.Cursor = 'Hand'; $b.BorderThickness = 1
    $b.Background = Brush $(if ($sel) { '#26FF7A12' } else { '#18181C' }); $b.BorderBrush = Brush $(if ($sel) { '#FF7A12' } else { '#18181C' })
    $g = New-Object Windows.Controls.Grid; $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)); $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = 'Auto'; $g.ColumnDefinitions.Add($cd)
    $sp = New-Object Windows.Controls.StackPanel; [void]$sp.Children.Add((T $t[1] 14 '#F2F1EE' 'SemiBold')); $d = T $t[2] 12 '#85847F'; $d.Margin = '0,2,0,0'; [void]$sp.Children.Add($d)
    if ($t[0] -eq 'custom') {                                               # two file slots: "needs you" and "finished"
      foreach ($k in @(@('ask', 'When it needs you'), @('done', 'When it finishes'))) {
        $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,8,0,0'
        $cur = $script:C["$agent.custom_$($k[0])"]
        $pick = New-Object Windows.Controls.Button; $pick.Style = $script:Win.Resources['Btn']; $pick.Content = $(if ($cur) { 'Change' } else { 'Choose file' }); $pick.Tag = @{ agent = $agent; kind = $k[0] }
        $pick.Add_Click({ param($x, $ev) $ev.Handled = $true
          $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'Sound (*.wav;*.mp3)|*.wav;*.mp3'; $dlg.Title = 'Pick a sound for Blink'
          if ($dlg.ShowDialog($script:Win)) {
            $dir = Join-Path (Split-Path $conf) 'sounds'; New-Item -ItemType Directory -Force $dir | Out-Null
            $dst = Join-Path $dir ("$($x.Tag.agent)_$($x.Tag.kind)" + [IO.Path]::GetExtension($dlg.FileName).ToLower())
            Copy-Item $dlg.FileName $dst -Force                             # a copy, so moving the original never breaks it
            $script:C["$($x.Tag.agent).custom_$($x.Tag.kind)"] = $dst; $script:C["$($x.Tag.agent).theme"] = 'custom'; Save-Now
            Play-Sound 'custom' $x.Tag.kind $script:C['volume'] $x.Tag.agent; Render-Page } })
        $lab = T ($k[1] + ':  ' + $(if ($cur) { [IO.Path]::GetFileName($cur) } elseif ($k[0] -eq 'done') { 'same as above' } else { 'no file yet' })) 12 '#B4B2AC'
        $lab.VerticalAlignment = 'Center'; $lab.Margin = '10,0,0,0'
        [void]$row.Children.Add($pick); [void]$row.Children.Add($lab); [void]$sp.Children.Add($row)
      }
    }
    [void]$g.Children.Add($sp)
    if ($t[0] -ne 'off' -and ($t[0] -ne 'custom' -or $script:C["$agent.custom_ask"])) {
      $p = New-Object Windows.Controls.Button; $p.Style = $script:Win.Resources['Btn']; $p.Margin = '0'; $p.VerticalAlignment = 'Top'; $p.Content = [char]0x25B6 + '  Listen'; $p.Tag = @{ theme = $t[0]; agent = $agent }
      $p.Add_Click({ param($x, $ev) $ev.Handled = $true; Play-Sound $x.Tag.theme 'ask' $script:C['volume'] $x.Tag.agent })
      [Windows.Controls.Grid]::SetColumn($p, 1); [void]$g.Children.Add($p)
    }
    $b.Child = $g; $b.Tag = @{ key = "$agent.theme"; value = $t[0]; agent = $agent }
    $b.Add_MouseLeftButtonUp({ param($x) $script:C[$x.Tag.key] = $x.Tag.value; Save-Now; Play-Sound $x.Tag.value 'ask' $script:C['volume'] $x.Tag.agent; Render-Page })
    Add $b
  }
}
function Pos-Name($p) { if ($p -eq 'free') { 'where you dragged it' } else { $p -replace '-', ' ' } }
function Position-Picker($key) {
  # A small screen: click where it should appear.
  $cv = New-Object Windows.Controls.Canvas; $cv.Width = 180; $cv.Height = 108
  $scr = New-Object Windows.Shapes.Rectangle; $scr.Width = 180; $scr.Height = 108; $scr.RadiusX = 8; $scr.RadiusY = 8; $scr.Fill = Brush '#0E0E10'; $scr.Stroke = Brush '#34343A'; [void]$cv.Children.Add($scr)
  $bar = New-Object Windows.Shapes.Rectangle; $bar.Width = 180; $bar.Height = 10; $bar.Fill = Brush '#1E1E22'; [Windows.Controls.Canvas]::SetTop($bar, 98); [void]$cv.Children.Add($bar)
  foreach ($p in @(@('top-left', 8, 8), @('top-center', 67, 4), @('top-right', 126, 8), @('bottom-left', 8, 76), @('bottom-center', 67, 76), @('bottom-right', 126, 76))) {
    $r = New-Object Windows.Controls.Border; $r.Width = 46; $r.Height = 16; $r.CornerRadius = 5; $r.Cursor = 'Hand'; $r.Tag = @{ key = $key; value = $p[0] }
    $sel = $script:C[$key] -eq $p[0]; $r.Background = Brush $(if ($sel) { '#FF7A12' } else { '#2C2C32' })
    [Windows.Controls.Canvas]::SetLeft($r, $p[1]); [Windows.Controls.Canvas]::SetTop($r, $p[2])
    $r.Add_MouseLeftButtonUp({ param($x) $script:C[$x.Tag.key] = $x.Tag.value; Save-Now; Render-Page }); [void]$cv.Children.Add($r)
  }
  $cv
}
function Seg($key, $options) {           # a few plain choices side by side
  $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
  foreach ($o in $options) { $on = $script:C[$key] -eq $o[0]
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = 8; $b.Padding = '11,6'; $b.Margin = '4,0,0,0'; $b.Cursor = 'Hand'; $b.Tag = @{ key = $key; value = $o[0] }
    $b.Background = Brush $(if ($on) { '#FF7A12' } else { '#26262B' }); $b.Child = (T $o[1] 12.5 $(if ($on) { '#111113' } else { '#C9C7C1' }) $(if ($on) { 'SemiBold' } else { $null }))
    $b.Add_MouseLeftButtonUp({ param($x) $script:C[$x.Tag.key] = $x.Tag.value; Save-Now; Render-Page }); [void]$sp.Children.Add($b) }
  $sp
}
function Swatches($key, $colors) {
  $sw = New-Object Windows.Controls.StackPanel; $sw.Orientation = 'Horizontal'
  foreach ($p in $colors) { $d = New-Object Windows.Shapes.Ellipse; $d.Width = 18; $d.Height = 18; $d.Margin = '3,0,3,0'; $d.Fill = Brush $p; $d.Cursor = 'Hand'; $d.Tag = @{ key = $key; value = $p }
    if ($script:C[$key] -eq $p) { $d.Stroke = Brush '#F2F1EE'; $d.StrokeThickness = 2 }
    $d.Add_MouseLeftButtonUp({ param($x) $script:C[$x.Tag.key] = $x.Tag.value; Save-Now; Render-Page }); [void]$sw.Children.Add($d) }
  $sw
}
function Preview-Bar {                   # four sample agents on the real bar, so you see every change as you make it
  $n = 0; foreach ($a in @(@('Fix the checkout page', 'getncloud', 'work'), @('Migrate the users table', 'api', 'ask'), @('Speed up the hero', 'landing', 'done'), @('Debounce the keys', 'firmware', 'work'))) { $n++
    [void](Track @{ key = "preview-$n"; agent = 'claude'; project = $a[1]; session = $a[0]; kind = $a[2] } $script:C) }
  Update-Dock $script:C
  $script:PreviewEnd = [DateTime]::Now.AddSeconds(30)
}

$script:Tab = 'claude'; $script:PrevKind = 'ask'
$PAGES = [ordered]@{ claude = 'Claude Code'; codex = 'Codex'; agents = 'Agent bar'; card = 'Card'; look = 'Look and motion'; sound = 'Sound'; pad = 'n.cloud pad' }
function Render-Nav {
  $nav = $script:Win.FindName('Nav'); $nav.Children.Clear()
  foreach ($k in $PAGES.Keys) {
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = 9; $b.Padding = '12,9'; $b.Margin = '0,0,0,3'; $b.Cursor = 'Hand'; $b.Tag = $k
    $on = $script:Tab -eq $k; $b.Background = Brush $(if ($on) { '#1F1F24' } else { '#00000000' })
    $t = T $PAGES[$k] 13.5 $(if ($on) { '#F2F1EE' } else { '#9A9893' }) $(if ($on) { 'SemiBold' } else { $null }); $b.Child = $t
    $b.Add_MouseLeftButtonUp({ param($x) $script:Tab = $x.Tag; Render-Nav; Render-Page; Update-Preview; Fade-In $script:Page 10 240 }); [void]$nav.Children.Add($b)
  }
}
function Render-Page {
  $script:Page.Children.Clear(); $c = $script:C
  switch ($script:Tab) {
    'claude' {
      H1 'Claude Code' 'Choose when Claude should call you, and how it sounds.'
      [void](Row 'Notify me about Claude Code' $null (Switch 'claude.enabled' '1' '0'))
      if ($c['claude.enabled'] -ne '0') {
        Group 'Call me when Claude'
        [void](Row 'Asks permission' 'For example, to run a command or edit a file.' (Switch 'claude.on_permission' '1' '0'))
        [void](Row 'Asks me a question' 'When it offers you options to pick from.' (Switch 'claude.on_question' '1' '0'))
        $ring = $c['claude.done_after'] -ne 'never'
        [void](Row 'Finishes its work' $null (Switch 'claude.done_after' { if ($script:C['claude.done_last']) { $script:C['claude.done_last'] } else { '30' } } 'never'))
        if ($ring) { $r = Range 'claude.done_after' 0 180 5 { param($v) if ($v -eq 0) { 'every time' } else { 'over ' + (Secs $v) } }
                     [void](Row 'But only if it worked for' 'So you are not called after quick replies you were watching anyway.' $r.panel)
                     $r.slider.Add_ValueChanged({ param($x) $script:C['claude.done_last'] = [string][int]$x.Value }) }
        Group 'Answer from the card'
        [void](Row 'Allow and Deny buttons on the card' 'One click answers that one request, like pressing it in the terminal. Shown only when the card can show the whole command.' (Switch 'claude.quick' '1' '0'))
        if ($c['claude.quick'] -ne '0') { $r = Range 'claude.quick_wait' 5 60 5 { param($v) Secs $v }; [void](Row 'Time to click' 'After that, answer in the terminal as usual.' $r.panel) }
        Group 'Sound for Claude Code'; Sound-Picker 'claude'
      }
    }
    'codex' {
      H1 'Codex' 'Codex tells Blink when it finishes. It cannot ask for permission through Blink, so there are no buttons here.'
      [void](Row 'Notify me about Codex' $null (Switch 'codex.enabled' '1' '0'))
      if ($c['codex.enabled'] -ne '0') {
        Group 'Call me when Codex'
        [void](Row 'Finishes its work' $null (Switch 'codex.done_after' '0' 'never'))
        Group 'Sound for Codex'
        $s = T 'Pick a different sound than Claude Code, and you will know who called without looking.' 12 '#85847F'; $s.Margin = '0,0,0,8'; Add $s
        Sound-Picker 'codex'
        Group 'Connect Codex (once)'
        $line = 'notify = ["sh", "' + ((Join-Path $root 'scripts\bell.sh') -replace '\\', '/') + '", "codex"]'
        $s = T 'Paste this line into %USERPROFILE%\.codex\config.toml. Codex keeps only one such line: if one is already there, this replaces it.' 12 '#85847F'; $s.Margin = '0,0,0,8'; Add $s
        $tb = New-Object Windows.Controls.TextBox; $tb.Text = $line; $tb.IsReadOnly = $true; $tb.TextWrapping = 'Wrap'; $tb.FontFamily = 'Cascadia Mono, Consolas'; $tb.FontSize = 12
        $tb.Background = Brush '#0C0C0E'; $tb.Foreground = Brush '#E6E4DF'; $tb.BorderBrush = Brush '#2C2C32'; $tb.Padding = '10,8'; $tb.Margin = '0,0,0,8'; Add $tb
        $cp = New-Object Windows.Controls.Button; $cp.Style = $script:Win.Resources['Btn']; $cp.Content = 'Copy the line'; $cp.HorizontalAlignment = 'Left'; $cp.Tag = $line
        $cp.Add_Click({ param($x) [Windows.Clipboard]::SetText($x.Tag); $x.Content = 'Copied' }); Add $cp
      }
    }
    'agents' {
      H1 'Agent bar' 'One dot per running agent. Put it where you like and make it yours.'
      [void](Row 'Show the agent bar' 'Hover it to see every agent and answer from the list. On a Mac it lives in the notch unless you move it.' (Switch 'dock' '1' '0'))
      if ($c['dock'] -ne '0') {
        $pv = New-Object Windows.Controls.Button; $pv.Style = $script:Win.Resources['Btn']; $pv.Content = 'Show sample agents for 30 s'; $pv.Add_Click({ Preview-Bar })
        [void](Row 'See it while you change it' 'Sample agents appear on the real bar.' $pv)
        Group 'Where'
        [void](Row "Now: $(Pos-Name $c['dock_pos'])" 'Click a spot, or hold the bar and drag it anywhere on the screen. Near a corner it snaps in.' (Position-Picker 'dock_pos'))
        [void](Row 'Lock it in place' 'Dragging the bar does nothing.' (Switch 'dock_lock' '1' '0'))
        Group 'Look'
        $r = Range 'dock_size' 70 180 5 { param($v) "$([int]$v) %" }; [void](Row 'Size' $null $r.panel)
        $r = Range 'dock_alpha' 40 100 5 { param($v) "$([int]$v) %" }; [void](Row 'Opacity' $null $r.panel)
        $r = Range 'dock_round' 0 24 2 { param($v) "$([int]$v) px" }; [void](Row 'Rounded corners' $null $r.panel)
        [void](Row 'Background' $null (Seg 'dock_bg' @(@('black', 'Black'), @('graphite', 'Graphite'), @('glass', 'Glass'))))
        [void](Row 'Show the eyes' 'Off leaves only the dots.' (Switch 'dock_eyes' '1' '0'))
        Group 'Behaviour'
        [void](Row 'Open the list' $null (Seg 'dock_open' @(@('hover', 'On hover'), @('click', 'On click'), @('never', 'Never'))))
        [void](Row 'Show the bar' 'Only when needed keeps the screen clean until an agent asks for you.' (Seg 'dock_when' @(@('always', 'Always'), @('ask', 'Only when needed'))))
      }
      Group 'Colours'
      $s = T 'New agents take the next free colour. Pin one to a project and it keeps it every time.' 12 '#85847F'; $s.Margin = '0,0,0,8'; Add $s
      $names = @($c.Keys | Where-Object { $_ -like 'color.*' } | ForEach-Object { $_.Substring(6) })
      if (-not $names) { $s = T 'Nothing pinned yet. Click a dot in the agent bar, or add a project below.' 12.5 '#B4B2AC'; Add $s }
      foreach ($n in $names) { [void](Row $n $null (Swatches "color.$n" $PALETTE)) }
    }
    'look' {
      H1 'Look and motion' 'How everything moves, and what the eyes look like.'
      Group 'Icon by the clock'
      [void](Row 'Show the Blink icon' 'In the tray next to the clock. Click it for these settings, right click for a quick menu.' (Switch 'tray' '1' '0'))
      [void](Row 'Start with Windows' 'The icon is there from the start, before your first agent runs.' (Switch 'autostart' '1' '0'))
      Group 'Animation'
      [void](Row 'Animate' 'Off makes every change instant.' (Switch 'anim' '1' '0'))
      if ($c['anim'] -ne '0') { $r = Range 'anim_speed' 50 250 10 { param($v) "$([int]$v) %" }; [void](Row 'Speed' 'Higher is quicker.' $r.panel) }
      Group 'Eyes'
      [void](Row 'When an agent needs you' $null (Swatches 'eye_ask' @('#FF7A12', '#FF4D4D', '#F5D04E', '#FF6FAE', '#B18CFF')))
      [void](Row 'While it works and when it is done' $null (Swatches 'eye_work' @('#4DA3FF', '#4CC38A', '#3FD0D4', '#B18CFF', '#F2F1EE')))
    }
    'card' {
      H1 'Card' 'The small window that shows who needs you and what for. It never takes the keyboard away from what you are doing.'
      [void](Row 'Show a card' 'Turn off to get only the sound.' (Switch 'popup' '1' '0'))
      if ($c['popup'] -ne '0') {
        Group 'Where on the screen'
        [void](Row "Now: $(Pos-Name $c['position'])" 'Click a spot on the little screen. Top right stays out of the way of Windows notifications, top center looks like an island.' (Position-Picker 'position'))
        Group 'Look'
        $r = Range 'card_size' 70 160 5 { param($v) "$([int]$v) %" }; [void](Row 'Size' $null $r.panel)
        $r = Range 'card_alpha' 50 100 5 { param($v) "$([int]$v) %" }; [void](Row 'Opacity' $null $r.panel)
        Group 'How long it stays'
        $stay = $c['card_ask'] -eq 'stay'
        [void](Row 'Keep "needs you" cards until I close them' 'Good if you often step away.' (Switch 'card_ask' 'stay' '25'))
        if (-not $stay) { $r = Range 'card_ask' 5 120 5 { param($v) Secs $v }; [void](Row 'Hide "needs you" cards after' 'Hold the mouse over a card to keep it open.' $r.panel) }
        $r = Range 'card_done' 3 30 1 { param($v) Secs $v }; [void](Row 'Hide "finished" cards after' $null $r.panel)
        Group 'What it shows'
        [void](Row 'Show the command' 'Turn off when you stream or share your screen. The Allow button hides with it.' (Switch 'show_cmd' '1' '0'))
      }
    }
    'sound' {
      H1 'Sound' 'How loud, and when to keep quiet. Pick the sounds themselves on the Claude Code and Codex pages.'
      $r = Range 'volume' 0 100 5 { param($v) "$([int]$v) %" }
      $r.slider.Add_PreviewMouseUp({ Play-Sound $script:C['claude.theme'] 'ask' $script:C['volume'] 'claude' })
      [void](Row 'Volume' 'Let go of the slider to hear it.' $r.panel)
      Group 'Quiet hours'
      $q = $c['quiet']; $qon = $q -match '^\d\d-\d\d$'
      [void](Row 'No sound at night' 'Cards still show, only the sound is off.' (Switch 'quiet' { '22-08' } 'off'))
      if ($qon) {
        $a = [int]$q.Substring(0, 2); $b = [int]$q.Substring(3, 2)
        $ra = Range $null 0 23 1 { param($v) '{0:00}:00' -f [int]$v } $a; $rb = Range $null 0 23 1 { param($v) '{0:00}:00' -f [int]$v } $b
        $ra.slider.Tag.which = 'a'; $rb.slider.Tag.which = 'b'
        foreach ($s in $ra.slider, $rb.slider) { $s.Add_ValueChanged({ param($x) $p = $script:C['quiet'].Split('-'); if ($x.Tag.which -eq 'a') { $p[0] = '{0:00}' -f [int]$x.Value } else { $p[1] = '{0:00}' -f [int]$x.Value }; $script:C['quiet'] = $p -join '-'; Save-Now }) }
        [void](Row 'Quiet from' $null $ra.panel); [void](Row 'Until' $null $rb.panel)
      }
    }
    'pad' {
      $img = New-Object Windows.Controls.Image; $img.Source = New-Object Windows.Media.Imaging.BitmapImage ([Uri](Join-Path $root 'assets\pad.png')); $img.Height = 230; $img.Margin = '0,6,0,6'; Add $img
      $k = T 'N.CLOUD NC-XX' 11 '#FF7A12'; $k.FontFamily = 'Cascadia Mono, Consolas'; Add $k
      $h = T 'Answer your agent with real keys' 24 '#F2F1EE' 'SemiBold'; $h.Margin = '0,6,0,8'; Add $h
      $p = T 'Blink tells you when your agent needs you. nc-xx lets you answer without hunting for the terminal: nine keys and two status eyes for AI coding agents.' 13.5 '#B4B2AC'; $p.Margin = '0,0,0,14'; Add $p
      foreach ($f in @('Allow, Deny, the arrows, Enter and a mic key, plus one key of your own', 'Every key remappable in a free app', 'Two status eyes: blue while your agent works, orange when it needs you', '500 numbered pads')) {
        $l = T ([char]0x2014 + '  ' + $f) 13 '#C9C7C1'; $l.Margin = '0,0,0,6'; Add $l }
      $cta = New-Object Windows.Controls.Button; $cta.Style = $script:Win.Resources['Cta']; $cta.Content = 'Join the waitlist on getncloud.com'; $cta.HorizontalAlignment = 'Left'; $cta.Margin = '0,12,0,0'
      $cta.Add_Click({ Open-Url $SITE }); Add $cta
    }
  }
}
function Update-Preview {
  $host_ = $script:Win.FindName('PrevHost'); $c = $script:C
  $agent = if ($script:Tab -eq 'codex') { 'codex' } else { 'claude' }; $ask = $script:PrevKind -eq 'ask'
  if ($agent -eq 'codex') { $ask = $false }
  $e = @{ agent = $agent; kind = $(if ($ask) { 'ask' } else { 'done' }); project = 'getncloud'; session = 'Fix the checkout page'; title = $(if ($ask) { 'Needs you' } else { 'Finished' })
          msg = $(if ($ask) { 'Allow this command?' } else { 'Your turn.' }); reply = $(if ($ask -and $c['claude.quick'] -ne '0') { 'test-preview' } else { '' }) }
  $d = @{ text = 'npm run build'; safe = $true; tool = 'Bash' }
  if (-not $script:PrevCard) { $script:PrevCard = [Windows.Markup.XamlReader]::Parse($CARD_BORDER); $host_.Content = $script:PrevCard }
  Fill-Card $script:PrevCard $e $c $d
  if (-not $ask) { Blink-Eyes $script:PrevCard 2 }
  if ($ask -and $e.reply) { $script:PrevCard.FindName('Bar').Width = 200 }
  $kinds = $script:Win.FindName('PrevKinds'); $kinds.Children.Clear()
  foreach ($k in @(@('ask', 'Needs you'), @('done', 'Finished'))) {
    if ($agent -eq 'codex' -and $k[0] -eq 'ask') { continue }
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = 8; $b.Padding = '10,5'; $b.Margin = '0,0,6,0'; $b.Cursor = 'Hand'; $b.Tag = $k[0]
    $on = ($k[0] -eq 'ask') -eq $ask; $b.Background = Brush $(if ($on) { '#1F1F24' } else { '#00000000' })
    $b.Child = (T $k[1] 12 $(if ($on) { '#F2F1EE' } else { '#85847F' }))
    $b.Add_MouseLeftButtonUp({ param($x) $script:PrevKind = $x.Tag; Update-Preview }); [void]$kinds.Children.Add($b)
  }
  $pos = Pos-Name $c['position']
  $NAMES = @{ eyes = 'Marimba'; glass = 'Soft tones'; bell = 'Desk bell'; system = 'Windows'; custom = 'your own' }
  $snd = if ($c["$agent.theme"] -eq 'off') { 'no sound' } else { "the $($NAMES[$c["$agent.theme"]]) sound" }
  $script:Win.FindName('PrevNote').Text = if ($c['popup'] -eq '0') { "Card is off: you will only hear $snd." } else { "Shows $pos of your screen with $snd." }
}
function Ensure-AppEntry {
  # So the settings open like an app: an "blink" entry in Start with the two-eyes icon, and its own taskbar button.
  $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Blink.lnk'
  $vbs = Join-Path $PSScriptRoot 'open-settings.vbs'; $ico = Join-Path $root 'assets\icon.ico'
  if ((Test-Path $lnk) -and ((Read-Conf)['link_target'] -eq $vbs)) { return }   # plugin updates move the folder: re-point it
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class BlinkLink {
  [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellLinkW { void GetPath(IntPtr a, int b, IntPtr c, int d); void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
    void GetDescription(IntPtr a, int b); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetWorkingDirectory(IntPtr a, int b); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetArguments(IntPtr a, int b); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetHotkey(out short h); void SetHotkey(short h); void GetShowCmd(out int c); void SetShowCmd(int c);
    void GetIconLocation(IntPtr a, int b, out int i); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, int r); void Resolve(IntPtr h, int f); void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s); }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PropKey k); void GetValue(ref PropKey k, IntPtr v); void SetValue(ref PropKey k, ref PropVar v); void Commit(); }
  [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPersistFile { void GetClassID(out Guid g); void IsDirty(); void Load([MarshalAs(UnmanagedType.LPWStr)] string f, int m);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string f, bool r); void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f); void GetCurFile(out IntPtr f); }
  [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PropKey { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Sequential)] struct PropVar { public ushort vt; ushort r1, r2, r3; public IntPtr p; IntPtr p2; }
  [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink {}
  [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
  public static void Create(string lnk, string target, string args, string icon, string appId) {
    var link = (IShellLinkW)new ShellLink(); link.SetPath(target); link.SetArguments(args); link.SetIconLocation(icon, 0);
    link.SetDescription("Blink settings: sounds and cards for your coding agent");
    var key = new PropKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };   // System.AppUserModel.ID
    var v = new PropVar { vt = 31, p = Marshal.StringToCoTaskMemUni(appId) };                      // VT_LPWSTR
    var store = (IPropertyStore)link; store.SetValue(ref key, ref v); store.Commit(); Marshal.FreeCoTaskMem(v.p);
    ((IPersistFile)link).Save(lnk, true);
  }
}
'@ -ErrorAction SilentlyContinue
  try {
    [BlinkLink]::Create($lnk, (Join-Path $env:WINDIR 'System32\wscript.exe'), "`"$vbs`"", $ico, 'ncloud.blink')
    $c = Read-Conf; $c['link_target'] = $vbs; Save-Conf $c
  } catch {}
}
function Open-Settings {
  Ensure-AppEntry
  try { [void][BlinkLink]::SetCurrentProcessExplicitAppUserModelID('ncloud.blink') } catch {}   # own taskbar button, not PowerShell's
  $script:C = Read-Conf; $script:Win = [Windows.Markup.XamlReader]::Parse($SET_XAML); $script:Page = $script:Win.FindName('Page')
  $script:Win.Title = 'Blink'
  try { $script:Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $root 'assets\icon.ico')) } catch {}
  try { $v = (Get-Content (Join-Path $root '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version; $script:Win.FindName('Ver').Text = "version $v" } catch {}
  foreach ($n in 'Head', 'Drag') { $script:Win.FindName($n).Add_MouseLeftButtonDown({ $script:Win.DragMove() }) }
  $script:Win.FindName('X').Add_MouseLeftButtonUp({ $script:Win.Close() })
  $script:Win.FindName('PromoImg').Source = New-Object Windows.Media.Imaging.BitmapImage ([Uri](Join-Path $root 'assets\pad.png'))
  $script:Win.FindName('Promo').Add_MouseLeftButtonUp({ $script:Tab = 'pad'; Render-Nav; Render-Page; Update-Preview })
  $script:Win.FindName('TryAsk').Add_Click({ $a = if ($script:Tab -eq 'codex') { 'codex' } else { 'claude' }; $ask = $a -eq 'claude'
    Handle @{ agent = $a; kind = $(if ($ask) { 'ask' } else { 'done' }); key = "test-$a"; project = 'getncloud'; theme = $script:C["$a.theme"]; popup = '1'
              title = $(if ($ask) { 'Needs you' } else { 'Finished' }); msg = $(if ($ask) { 'Allow this command?' } else { 'Your turn.' }); cmd = 'npm run build'
              reply = $(if ($ask -and $script:C['claude.quick'] -ne '0') { 'test-claude' } else { '' }); wait = $script:C['claude.quick_wait'] } })
  $script:Win.FindName('TryDone').Add_Click({ $a = if ($script:Tab -eq 'codex') { 'codex' } else { 'claude' }
    Handle @{ agent = $a; kind = 'done'; key = "test-$a-done"; project = 'getncloud'; theme = $script:C["$a.theme"]; popup = '1'; title = 'Finished'; msg = 'Your turn.' } })
  Render-Nav; Render-Page; Update-Preview
  $script:Win.Add_Closed({ foreach ($x in @($cards)) { $x.Close() }; if ($script:DockWin) { $script:DockWin.Close() }; [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
  $script:Win.Opacity = 0; $script:Win.Show()
  $script:Win.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(220))))
  Fade-In $script:Page 14 320
}

# ---- main loop -----------------------------------------------------------------------------------------------
$last = [DateTime]::Now
$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(40)
$hbAt = [DateTime]::MinValue; $script:ConfSeen = [DateTime]::MinValue; $script:PreviewEnd = [DateTime]::MaxValue
$timer.Add_Tick({
  $now = [DateTime]::Now
  if ($Mode -ne 'settings') {
    if ($Mode -ne 'demo') { foreach ($f in [IO.Directory]::GetFiles($spool, '*.evt')) {
      try { $e = Read-Event $f; Remove-Item $f -Force; if ($e.kind) { Handle $e; $script:last = $now } } catch { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    } }
    if (($now - $script:hbAt).TotalSeconds -ge 5) { [IO.File]::WriteAllText((Join-Path $state 'heartbeat'), ''); $script:hbAt = $now; Prune; if ($script:DockOpen) { Dock-Rows } }
    if ($script:Demo.Count -and $now -ge $script:Demo[0].at) { $x = $script:Demo[0]; $script:Demo.RemoveAt(0); try { & $x.do } catch { Add-Content (Join-Path $state "demo.log") ("$_ @ " + $_.InvocationInfo.PositionMessage) } }
    if (($now - $script:last).TotalHours -ge 4 -and $cards.Count -eq 0 -and $sessions.Count -eq 0 -and -not $script:Tray) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
  }
  foreach ($w in @($cards)) { if ($now -gt $w.Tag.until) { Close-Card $w } }
  if ($now -gt $script:DockHide) { $script:DockHide = [DateTime]::MaxValue; if ($script:DockWin) { $script:DockWin.Close(); $script:DockWin = $null; Layout-Cards $script:DC } }
  if ($now -gt $script:PreviewEnd) { $script:PreviewEnd = [DateTime]::MaxValue; foreach ($k in 1..4) { $sessions.Remove("preview-$k") }; Update-Dock $script:DC }
  if ($Mode -ne 'settings' -and ($now - $script:ConfSeen).TotalMilliseconds -ge 300) { $script:ConfSeen = $now
    try { $t = [IO.File]::GetLastWriteTimeUtc($conf); if ($t -ne $script:ConfAt) { $script:ConfAt = $t; Conf-Changed (Read-Conf) } } catch {} }
})
$timer.Start()
function Save-Png($el, $path, $w, $h) {
  $s = 1.5; $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]([double]$w * $s), [int]([double]$h * $s), [double](96 * $s), [double](96 * $s), [Windows.Media.PixelFormats]::Pbgra32)
  $bmp.Render($el); $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
}
function Still($el) { foreach ($n in 'EyeL', 'EyeR') { $r = $el.FindName($n); if ($r) { $r.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $r.Opacity = 1; $r.RenderTransform = $null } } }
function Pump { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) }
function Snapshot($dir) {
  # The settings pages exactly as the window draws them (off screen), then three sample cards.
  New-Item -ItemType Directory -Force $dir | Out-Null
  Open-Settings; $script:Win.Left = -5000; $script:Win.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $script:Win.Opacity = 1
  $rootEl = $script:Win.Content
  foreach ($tab in 'claude', 'codex', 'agents', 'card', 'look', 'sound', 'pad') {
    $script:Tab = $tab; $script:PrevKind = 'ask'; Render-Nav; Render-Page; Update-Preview
    $script:Page.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $script:Page.Opacity = 1; $script:Page.RenderTransform = $null; Still $script:PrevCard
    Pump; $script:Win.UpdateLayout(); Pump
    Save-Png $rootEl (Join-Path $dir "settings_$tab.png") $script:Win.ActualWidth $script:Win.ActualHeight
  }
  $c = Read-Conf; $c['show_cmd'] = '1'
  $samples = @(
    @('card_allow', @{ agent = 'claude'; kind = 'ask'; project = 'getncloud'; session = 'Fix the checkout page'; title = 'Needs you'; msg = 'Allow this command?'; reply = 'test-x'; wait = '20' }, @{ text = 'npm run build && npm run deploy'; safe = $true; tool = 'Bash' }),
    @('card_long', @{ agent = 'claude'; kind = 'ask'; project = 'api'; session = 'Migrate the users table'; title = 'Needs you'; msg = 'Allow Edit?'; reply = 'test-y'; wait = '20' }, @{ text = 'Edit: {"file_path":"src/db/migrate.ts","old_string":"...","new_string":"..."}'; safe = $false; tool = 'Edit' }),
    @('card_done', @{ agent = 'codex'; kind = 'done'; project = 'landing'; title = 'Finished'; msg = 'Done: the hero section now loads in 0.8 s.' }, @{ text = ''; safe = $false; tool = '' }))
  foreach ($s in $samples) {
    $el = [Windows.Markup.XamlReader]::Parse($CARD_BORDER); Fill-Card $el $s[1] $c $s[2]; Still $el
    if ($s[1].reply) { $el.FindName('Bar').Width = 150 }
    $el.Measure((New-Object Windows.Size(420, [double]::PositiveInfinity))); $el.Arrange((New-Object Windows.Rect(0, 0, 420, $el.DesiredSize.Height))); $el.UpdateLayout()
    Save-Png $el (Join-Path $dir "$($s[0]).png") 420 $el.DesiredSize.Height
  }
  $script:Win.Close()
}
$script:Demo = New-Object Collections.ArrayList
function Demo-Step($sec, $block) { [void]$script:Demo.Add(@{ at = [DateTime]::Now.AddSeconds($sec); do = $block }) }
function Demo {                          # four agents at work: for screen recordings and for checking the bar and the cards
  $base = @{ theme = 'eyes'; popup = '1' }
  function script:Ev($key, $agent, $project, $session, $kind, $more) { $e = @{ key = $key; agent = $agent; project = $project; session = $session; kind = $kind; theme = 'eyes'; popup = '1' }; if ($more) { foreach ($k in $more.Keys) { $e[$k] = $more[$k] } }; Handle $e }
  Demo-Step 0.5 { Ev 'demo-1' 'claude' 'getncloud' 'Fix the checkout page' 'work' }
  Demo-Step 1.3 { Ev 'demo-2' 'claude' 'api' 'Migrate the users table' 'work' }
  Demo-Step 2.1 { Ev 'demo-3' 'codex' 'landing' 'Speed up the hero section' 'work' }
  Demo-Step 2.9 { Ev 'demo-4' 'claude' 'firmware' 'Debounce the keys' 'work' }
  Demo-Step 5 { Ev 'demo-2' 'claude' 'api' 'Migrate the users table' 'ask' @{ title = 'Needs you'; msg = 'Allow this command?'; cmd = 'npm run migrate'; reply = 'test-demo'; wait = '12'; demo = '1' } }
  Demo-Step 7.5 { Dock-Open $true }
  Demo-Step 10 { Dock-Open $false }
  Demo-Step 11 { foreach ($w in @($cards)) { if ($w.Tag.key -eq 'demo-2') { Send-Reply $w 'allow' } } }
  Demo-Step 14 { Ev 'demo-3' 'codex' 'landing' 'Speed up the hero section' 'done' @{ title = 'Finished'; msg = 'The hero section now loads in 0.8 s.' } }
  Demo-Step 21 { foreach ($k in 'demo-1', 'demo-2', 'demo-3', 'demo-4') { Ev $k 'claude' '' '' 'end' } }
  Demo-Step 23 { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
}
if ($Mode -eq 'snapshot') { Snapshot $Out; exit }
if ($Mode -eq 'demo') { Preload (Read-Conf); Demo }
Conf-Changed (Read-Conf)
if ($Mode -eq 'settings') { Open-Settings } elseif ($Mode -ne 'demo') { Preload (Read-Conf) }
[Windows.Threading.Dispatcher]::Run()
if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
