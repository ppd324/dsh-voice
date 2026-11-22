param(
  [string]$StateFile = (Join-Path $PSScriptRoot 'state.json'),
  [int]$Margin = 36
)
# Floating voice orb (Grok-bot style): soft white head, two capsule eyes.
# Listening = pulsing ring, thinking = orbiting dots, speaking = happy arcs, error = X.
# Text comes from $StateFile (UTF-8), so this source stays ASCII-only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dpi = @'
using System;
using System.Runtime.InteropServices;
public class Dpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
}
'@
Add-Type -TypeDefinition $dpi
try { [Dpi]::SetProcessDpiAwareness(2) | Out-Null } catch { [Dpi]::SetProcessDPIAware() | Out-Null }

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\dsh-voice-orb', [ref]$created)
if (-not $created) { exit 0 }

$cardColor = [System.Drawing.Color]::FromArgb(15, 18, 25)

$formClass = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
public class OrbPanel : Panel {
  public OrbPanel() { this.DoubleBuffered = true; SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.SupportsTransparentBackColor, true); }
}
public class OrbForm : Form {
  public OrbForm() {
    SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    this.FormBorderStyle = FormBorderStyle.None;
    this.ShowInTaskbar = false;
    this.TopMost = true;
    this.StartPosition = FormStartPosition.Manual;
    this.BackColor = Color.FromArgb(15, 18, 25);
    this.Opacity = 1.0;
    this.Height = 96;
    this.Width = 460;
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000; return cp; }
  }
  public void Round(int radius) {
    var path = new GraphicsPath();
    var r = new Rectangle(0, 0, Width, Height);
    int d = radius * 2;
    path.AddArc(r.X, r.Y, d, d, 180, 90);
    path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
    path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
    path.CloseFigure();
    this.Region = new Region(path);
  }
}
'@
Add-Type -TypeDefinition $formClass -ReferencedAssemblies System.Windows.Forms, System.Drawing

$form = New-Object OrbForm

$face = New-Object OrbPanel
$face.Width = 64
$face.Height = 64
$face.Left = 28
$face.Top = 16
$face.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($face)

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $false
$label.Left = 104
$label.Top = 16
$label.Width = 336
$label.Height = 20
$label.ForeColor = [System.Drawing.Color]::FromArgb(150, 160, 180)
$label.BackColor = [System.Drawing.Color]::Transparent
$label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Regular)
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$form.Controls.Add($label)

$caption = New-Object System.Windows.Forms.Label
$caption.AutoSize = $false
$caption.Left = 104
$caption.Top = 38
$caption.Width = 336
$caption.Height = 44
$caption.ForeColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
$caption.BackColor = [System.Drawing.Color]::Transparent
$caption.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5, [System.Drawing.FontStyle]::Regular)
$caption.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$form.Controls.Add($caption)

$script:statePath = $StateFile
$script:accent = [System.Drawing.Color]::FromArgb(76, 154, 255)
$script:phase = 0.0
$script:level = 0.0
$script:expression = 'idle'
$script:bob = 0.0
$script:paints = 0
$script:lastFade = ''
$script:lastLabel = $null
$script:lastCaption = $null
$script:hiddenUntil = [DateTime]::MinValue
$script:idleTicks = 0
$script:blinkStart = $null
$script:nextBlink = (Get-Date).AddSeconds(3)
$script:gazeX = 0.0
$script:gazeY = 0.0
$script:targetX = 0.0
$script:targetY = 0.0
$script:parts = @()
$script:prevState = 'idle'
$script:logFile = Join-Path $PSScriptRoot 'orb.log'
$script:configPath = Join-Path $PSScriptRoot 'config.json'
$script:configStamp = 0
$script:orbStyle = 'bot'
$script:orbLogoPath = ''
$script:logoImage = $null

# 球的样式可以在控制面板里改;这里按配置文件时间戳热加载
function Refresh-OrbStyle {
  try {
    $st = (Get-Item $script:configPath -ErrorAction Stop).LastWriteTimeUtc.Ticks
    if ($st -eq $script:configStamp) { return }
    $script:configStamp = $st
    $cfg = Get-Content $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.orbStyle) { $script:orbStyle = [string]$cfg.orbStyle }
    $logo = [string]$cfg.orbLogo
    if ($logo -ne $script:orbLogoPath) {
      $script:orbLogoPath = $logo
      if ($script:logoImage) { try { $script:logoImage.Dispose() } catch {} ; $script:logoImage = $null }
      if ($logo -and (Test-Path $logo)) {
        try { $script:logoImage = [System.Drawing.Image]::FromFile($logo) } catch {}
      }
    }
  } catch {}
}

function Write-OrbLog([string]$m) {
  try { [System.IO.File]::AppendAllText($script:logFile, (Get-Date -Format o) + ' ' + $m + [Environment]::NewLine) } catch {}
}

function Write-Beat([string]$st) {
  try {
    $beat = '{"ts":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() +
      ',"state":"' + $st + '","visible":' + $form.Visible.ToString().ToLower() +
      ',"opacity":' + [math]::Round($form.Opacity, 2) +
      ',"idle":' + $script:idleTicks +
      ',"paints":' + $script:paints +
      ',"level":' + [math]::Round($script:level, 2) +
      ',"fade":"' + $script:lastFade + '"}'
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'orb.heartbeat'), $beat)
  } catch {}
}

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = [Math]::Min($r, [Math]::Min($w, $h) / 2.0)
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

$face.add_Paint({
  param($sender, $e)
  try {
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $script:paints++

    $w = $sender.Width; $h = $sender.Height
    $cx = $w / 2.0
    $cy = $h / 2.0 + $script:bob
    $expr = $script:expression
    $lvl = [Math]::Min(1.0, [Math]::Max(0.0, $script:level))

    # --- ring effects --------------------------------------------------------
    if ($expr -eq 'thinking') {
      for ($i = 0; $i -lt 6; $i++) {
        $ang = $script:phase * 1.1 + $i * ([Math]::PI / 3)
        $dx = [Math]::Cos($ang) * 27.0
        $dy = [Math]::Sin($ang) * 27.0
        $fd = 0.25 + 0.75 * [Math]::Abs([Math]::Sin($ang - $script:phase))
        $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb([int](210 * $fd), $script:accent))
        $g.FillEllipse($b, ($cx + $dx - 2.2), ($cy + $dy - 2.2), 4.4, 4.4)
        $b.Dispose()
      }
    } elseif ($expr -eq 'listening') {
      $al = [int](40 + 50 * [Math]::Abs([Math]::Sin($script:phase)))
      $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($al, $script:accent), 1.6)
      $ringR = 24.0 + 1.6 * [Math]::Sin($script:phase) + 4.0 * $lvl
      $g.DrawEllipse($pen, $cx - $ringR, $cy - $ringR, $ringR * 2, $ringR * 2)
      $pen.Dispose()
    }

    # --- custom styles (replace the bot face) ------------------------------
    if ($script:orbStyle -eq 'logo' -and $script:logoImage) {
      $maxSide = 56.0
      $iw = [double]$script:logoImage.Width
      $ih = [double]$script:logoImage.Height
      $scale = [Math]::Min($maxSide / $iw, $maxSide / $ih)
      $dw = $iw * $scale
      $dh = $ih * $scale
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($script:logoImage, [single]($cx - $dw / 2), [single]($cy - $dh / 2), [single]$dw, [single]$dh)
      return
    }
    if ($script:orbStyle -eq 'bars') {
      $barW = 9.0
      $gap = 6.0
      $shape = @(0.55, 1.0, 0.7)
      $boost = 1.0 + 0.55 * $lvl
      for ($i = 0; $i -lt 3; $i++) {
        $bh = 32.0 * $shape[$i] * $boost
        $bx = $cx - (3 * $barW + 2 * $gap) / 2 + $i * ($barW + $gap)
        $bp = New-RoundPath $bx ($cy - $bh / 2) $barW $bh ($barW / 2)
        $bb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255))
        $g.FillPath($bb, $bp)
        $bb.Dispose()
        $bp.Dispose()
      }
      return
    }

    # --- head ---------------------------------------------------------------
    $grow = 1.0 + 0.06 * $lvl
    $hw = 44.0 * $grow
    $hh = 40.0 * $grow
    $headPath = New-RoundPath ($cx - $hw / 2) ($cy - $hh / 2) $hw $hh 16.0
    $headRect = New-Object System.Drawing.RectangleF(($cx - $hw / 2), ($cy - $hh / 2), $hw, $hh)
    $headBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($headRect,
      [System.Drawing.Color]::FromArgb(255, 255, 255),
      [System.Drawing.Color]::FromArgb(199, 209, 228), 70.0)
    $g.FillPath($headBrush, $headPath)
    $headBrush.Dispose()
    $rim = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 255, 255, 255)), 1.2
    $g.DrawPath($rim, $headPath)
    $rim.Dispose()
    $headPath.Dispose()

    # --- eyes ---------------------------------------------------------------
    $dark = [System.Drawing.Color]::FromArgb(18, 22, 30)
    $eyeW = 9.0
    $baseH = 12.5
    $gap = 10.5
    $eyeY = $cy - 3 + $script:gazeY
    $blink = 1.0
    if ($script:blinkStart) {
      $el = ((Get-Date) - $script:blinkStart).TotalMilliseconds
      if ($el -lt 150) { $blink = 1.0 - 0.92 * [Math]::Sin($el / 150.0 * [Math]::PI) }
    }

    if ($expr -eq 'speaking') {
      $pen = New-Object System.Drawing.Pen $dark, 2.8
      $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
      $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
      foreach ($sx in @(-1, 1)) {
        $ex = $cx + $sx * $gap + $script:gazeX
        $g.DrawArc($pen, ($ex - 5), ($eyeY - 2), 10, 9, 200, 140)
      }
      $pen.Dispose()
    } elseif ($expr -eq 'error') {
      $pen = New-Object System.Drawing.Pen $dark, 2.6
      $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
      $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
      foreach ($sx in @(-1, 1)) {
        $ex = $cx + $sx * $gap
        $g.DrawLine($pen, ($ex - 3.5), ($eyeY - 3), ($ex + 3.5), ($eyeY + 3))
        $g.DrawLine($pen, ($ex - 3.5), ($eyeY + 3), ($ex + 3.5), ($eyeY - 3))
      }
      $pen.Dispose()
    } else {
      foreach ($sx in @(-1, 1)) {
        $ex = $cx + $sx * $gap + $script:gazeX
        $eh = [Math]::Max(1.2, $baseH * $blink)
        $p = New-RoundPath ($ex - $eyeW / 2) ($eyeY - $eh / 2) $eyeW $eh 4.5
        $b = New-Object System.Drawing.SolidBrush $dark
        $g.FillPath($b, $p)
        $b.Dispose()
        $p.Dispose()
      }
    }

    # --- wake particles -----------------------------------------------------
    foreach ($pt in $script:parts) {
      $al = [int]([Math]::Max(0, [Math]::Min(255, 255 * $pt.life / $pt.max)))
      $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($al, $pt.color))
      $g.FillEllipse($b, ($cx + $pt.x - $pt.r), ($cy + $pt.y - $pt.r), $pt.r * 2, $pt.r * 2)
      $b.Dispose()
    }
  } catch {
    Write-OrbLog ('paint error: ' + $_.Exception.Message)
  }
})

function Read-State {
  try {
    $raw = [System.IO.File]::ReadAllText($script:statePath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}

$form.add_Shown({
  $form.Round(22)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Left = $wa.Right - $form.Width - $Margin
  $form.Top = $wa.Bottom - $form.Height - $Margin
})
$form.add_MouseClick({ $script:hiddenUntil = [DateTime]::Now.AddSeconds(1.5); $form.Hide() })

$gaze = {
  $sp = [System.Windows.Forms.Cursor]::Position
  $fx = $form.Left + $face.Left + $face.Width / 2
  $fy = $form.Top + $face.Top + $face.Height / 2
  $dx = $sp.X - $fx; $dy = $sp.Y - $fy
  $dist = [Math]::Sqrt($dx * $dx + $dy * $dy)
  if ($dist -gt 4) {
    $script:targetX = [Math]::Max(-3.0, [Math]::Min(3.0, $dx / $dist * 3.0))
    $script:targetY = [Math]::Max(-2.5, [Math]::Min(2.5, $dy / $dist * 2.5))
  } else { $script:targetX = 0.0; $script:targetY = 0.0 }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 33
$timer.add_Tick({
  try {
    $now = [DateTime]::Now
    if ($now -lt $script:hiddenUntil) { return }

    Refresh-OrbStyle
    $s = Read-State
    $state = 'idle'; $textNow = ''; $labelNow = ''
    if ($s) {
      $state = [string]$s.state
      $textNow = [string]$s.text
      $labelNow = [string]$s.label
      $ts = 0.0; [double]::TryParse(([string]$s.ts), [ref]$ts) | Out-Null
      if ($ts -gt 0) {
        $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if (($ms - $ts) -gt 20000) { $state = 'idle' }
      }
    }

    if ($state -eq 'idle') {
      $script:idleTicks++
      if ($form.Visible) { $form.Hide(); $script:lastFade = 'hidden' }
      Write-Beat 'idle'
      return
    }

    $script:idleTicks = 0
    if (-not $form.Visible) { $form.Show() }
    $form.Opacity = 1

    if ($now -gt $script:nextBlink) {
      $script:blinkStart = $now
      $script:nextBlink = $now.AddSeconds(3 + (Get-Random -Minimum 0 -Maximum 4))
    }
    if ($script:blinkStart -and (($now - $script:blinkStart).TotalMilliseconds -gt 170)) { $script:blinkStart = $null }

    $lvlIn = 0.0
    if ($null -ne $s -and $null -ne $s.level) { $lvlIn = [double]$s.level }
    $script:level = $script:level * 0.55 + $lvlIn * 0.45
    $script:phase += 0.14

    if ($state -ne $script:prevState) {
      if ($script:prevState -eq 'idle' -and $state -eq 'listening') {
        $script:parts = @()
        for ($i = 0; $i -lt 10; $i++) {
          $ang = (Get-Random -Minimum 0 -Maximum 360) * [Math]::PI / 180
          $spd = 1.2 + (Get-Random -Minimum 0 -Maximum 100) / 100.0 * 1.6
          $script:parts += [pscustomobject]@{
            x = 0.0; y = 0.0
            vx = [Math]::Cos($ang) * $spd
            vy = [Math]::Sin($ang) * $spd
            life = 16.0; max = 16.0; r = 1.4 + (Get-Random -Minimum 0 -Maximum 100) / 100.0
            color = [System.Drawing.Color]::FromArgb(255, 255, 255)
          }
        }
      }
      $script:prevState = $state
    }
    if ($script:parts.Count -gt 0) {
      $alive = @()
      foreach ($pt in $script:parts) {
        $pt.x += $pt.vx; $pt.y += $pt.vy
        $pt.vx *= 0.94; $pt.vy = $pt.vy * 0.94 + 0.06
        $pt.life -= 1
        if ($pt.life -gt 0) { $alive += $pt }
      }
      $script:parts = $alive
    }

    & $gaze
    $script:gazeX += ($script:targetX - $script:gazeX) * 0.22
    $script:gazeY += ($script:targetY - $script:gazeY) * 0.22

    switch ($state) {
      'listening' {
        $script:accent = [System.Drawing.Color]::FromArgb(76, 154, 255)
        $script:expression = 'listening'
        $script:bob = 0.8 * [Math]::Sin($script:phase * 0.8)
      }
      'heard' {
        $script:accent = [System.Drawing.Color]::FromArgb(76, 154, 255)
        $script:expression = 'listening'
        $script:bob = 0.0
      }
      'thinking' {
        $script:accent = [System.Drawing.Color]::FromArgb(255, 176, 32)
        $script:expression = 'thinking'
        $script:bob = 0.6 * [Math]::Sin($script:phase * 1.7)
        $script:gazeX = $script:gazeX * 0.6 + 1.6 * 0.4
        $script:gazeY = $script:gazeY * 0.6 - 1.8 * 0.4
      }
      'speaking' {
        $script:accent = [System.Drawing.Color]::FromArgb(52, 199, 89)
        $script:expression = 'speaking'
        $script:bob = 1.1 * [Math]::Sin($script:phase * 1.3)
      }
      'error' {
        $script:accent = [System.Drawing.Color]::FromArgb(255, 96, 92)
        $script:expression = 'error'
        $script:bob = 0.0
      }
      default {
        $script:accent = [System.Drawing.Color]::FromArgb(142, 142, 147)
        $script:expression = 'idle'
        $script:bob = 0.0
      }
    }

    if ($script:lastLabel -ne $labelNow) { $label.Text = $labelNow; $script:lastLabel = $labelNow }
    if ($script:lastCaption -ne $textNow) {
      $caption.Text = $textNow
      $script:lastCaption = $textNow
      # 按字符数估算行数(中文约 22 字/行), 2~5 行自适应
      # 用真实排版测量, 而不是按字数估算
      $lineH = 23
      $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        $textNow, $caption.Font,
        (New-Object System.Drawing.Size(($caption.Width - 6), 4000)),
        [System.Windows.Forms.TextFormatFlags]::WordBreak)
      $lines = [Math]::Max(2, [Math]::Min(6, [int][Math]::Ceiling($measured.Height / $lineH)))
      $newH = 54 + $lines * $lineH + 8
      if ($form.Height -ne $newH) {
        $caption.Height = $lines * $lineH
        $form.Height = $newH
        # 圆角 Region 是按旧高度算的, 不重算会把新增的行裁掉
        $form.Round(22)
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Top = $wa.Bottom - $form.Height - $Margin
        $face.Top = [int](($newH - $face.Height) / 2)
        $form.Invalidate()
      }
    }
    $face.Invalidate()
    $form.Invalidate()
    Write-Beat $state
  } catch {
    Write-OrbLog ('tick error: ' + $_.Exception.Message)
  }
})

$form.add_Paint({
  param($sender, $e)
  try {
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $sender.Width; $h = $sender.Height

    $body = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 21.5
    $rect = New-Object System.Drawing.RectangleF(0, 0, $w, $h)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
      [System.Drawing.Color]::FromArgb(28, 33, 45),
      [System.Drawing.Color]::FromArgb(13, 16, 22), 90.0)
    $g.FillPath($grad, $body)
    $grad.Dispose()
    $body.Dispose()

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(40, 255, 255, 255)), 1
    $edge = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 21.5
    $g.DrawPath($pen, $edge)
    $pen.Dispose()
    $edge.Dispose()

    $bar = New-RoundPath 11 20 4.5 ($h - 40) 2.2
    $b = New-Object System.Drawing.SolidBrush $script:accent
    $g.FillPath($b, $bar)
    $b.Dispose()
    $bar.Dispose()
  } catch {
    Write-OrbLog ('card paint error: ' + $_.Exception.Message)
  }
})

$form.add_FormClosed({ $timer.Stop(); [System.Windows.Forms.Application]::Exit() })
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
