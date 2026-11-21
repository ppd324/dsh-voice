param(
  [Parameter(Mandatory=$true)][string]$Text,
  [int]$Rate = 0,
  [int]$Volume = 100,
  [string]$VoiceMatch = 'Huihui|zh-CN'
)
# Speak text through SAPI (prefers the matching installed voice).
$ErrorActionPreference = 'Stop'
$v = New-Object -ComObject SAPI.SpVoice
try {
  if ($VoiceMatch) {
    $voices = @($v.GetVoices())
    for ($i = 0; $i -lt $voices.Count; $i++) {
      $desc = $voices.Item($i).GetDescription()
      if ($desc -match $VoiceMatch) { $v.Voice = $voices.Item($i); break }
    }
  }
  $v.Rate = $Rate
  $v.Volume = $Volume
  $v.Speak($Text) | Out-Null
} finally {
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($v)
}
