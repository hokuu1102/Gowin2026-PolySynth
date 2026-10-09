$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $PSScriptRoot 'mutant.v'
$out = Join-Path $PSScriptRoot 'mutant.vvp'
$base = @('../../rtl/hdmi/video_timing.v', 'rtl/color_bars.v', '../../rtl/hdmi/tmds_encoder.v')
$cases = @(
    @('H_TOTAL_799', '../../rtl/hdmi/video_timing.v', 'parameter integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP,', 'parameter integer H_TOTAL = 799,'),
    @('COLOR_SWAP', 'rtl/color_bars.v', '24''hffffff', '24''hffff00'),
    @('HSYNC_INVERT', '../../rtl/hdmi/video_timing.v', 'assign hsync = !(', 'assign hsync = ('),
    @('TOKEN_CTL10', '../../rtl/hdmi/tmds_encoder.v', '2''b10: next_symbol = 10''b0101010100;', '2''b10: next_symbol = 10''b0010101011;'),
    @('TOKEN_CTL00', '../../rtl/hdmi/tmds_encoder.v', '2''b00: next_symbol = 10''b1101010100;', '2''b00: next_symbol = 10''b1010101011;'),
    @('DISPARITY_ZERO', '../../rtl/hdmi/tmds_encoder.v', 'disparity <= next_disparity;', 'disparity <= 6''sd0;')
)
try {
    foreach ($case in $cases) {
        $name, $target, $from, $to = $case
        $source = Get-Content -Raw -LiteralPath (Join-Path $root $target)
        if (-not $source.Contains($from)) { throw "Missing mutation anchor: $name" }
        if ($name -eq 'COLOR_SWAP') {
            $source = $source.Replace("24'hffffff", "24'h123456").Replace("24'hffff00", "24'hffffff").Replace("24'h123456", "24'hffff00")
        } else { $source = $source.Replace($from, $to) }
        Set-Content -LiteralPath $tmp -Encoding ASCII -Value $source
        $files = @()
        foreach ($file in $base) {
            if ($file -eq $target) { $files += $tmp }
            else { $files += (Join-Path $root $file) }
        }
        $files += (Join-Path $root 'tb/tmds_decoder.sv')
        $files += (Join-Path $root 'tb/tb_hdmi_640x480.sv')
        & iverilog -g2012 -s tb_hdmi_640x480 -o $out $files
        if ($LASTEXITCODE -ne 0) { throw "Compile failed: $name" }
        $result = & vvp $out 2>&1
        $fail = @($result | Where-Object { $_ -match '^FAIL ' })
        if ($LASTEXITCODE -eq 0 -or $fail.Count -eq 0) { throw "Mutation escaped: $name" }
        Write-Host "MUTATION_PASS $name $($fail[0])"
    }
} finally {
    Remove-Item -LiteralPath $tmp, $out -ErrorAction SilentlyContinue
}
