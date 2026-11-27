param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$Evidence,
    [ValidateSet('click','text','keys','scroll')][string]$Action,
    [int]$X=0,[int]$Y=0,[int]$Wheel=0,
    [string]$Text='',[string]$TextFile='',
    [ValidateSet('','TAB','ENTER','ESC','CTRL_A','CLEAR','ALT_F4')][string]$Keys=''
)
$ErrorActionPreference='Stop'
$bundlePath=[IO.Path]::GetFullPath($Bundle).TrimEnd('\')
$allowedRoot='D:\demo2\bk-remote-toolchains\'
if (!$bundlePath.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -or ![IO.Path]::GetFullPath($Evidence).StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Only BK validation directories are allowed.' }
$exe=Join-Path $bundlePath 'BK Remote.exe'
$window=Get-Process -Name 'BK Remote' -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe -and $_.MainWindowHandle -ne 0} | Select-Object -First 1
if ($null -eq $window) { throw 'Candidate window not found.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BkUiInput {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd,out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,int data,UIntPtr extraInfo);
 [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KeyboardInput Keyboard; [FieldOffset(0)] public MouseInput Mouse; }
 [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public InputUnion Data; }
 [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, Input[] inputs, int size);
 public static void SendLiteralText(string text, IntPtr expectedWindow) {
  if (GetForegroundWindow() != expectedWindow) throw new InvalidOperationException("Candidate lost foreground before text input.");
  if (text.Length == 0) return;
  var inputs = new Input[text.Length * 2];
  for (int i=0; i<text.Length; i++) {
   inputs[2*i].Type=1; inputs[2*i].Data.Keyboard.Scan=(ushort)text[i]; inputs[2*i].Data.Keyboard.Flags=4;
   inputs[2*i+1].Type=1; inputs[2*i+1].Data.Keyboard.Scan=(ushort)text[i]; inputs[2*i+1].Data.Keyboard.Flags=6;
  }
  if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input))) != (uint)inputs.Length)
   throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Literal text input was not fully delivered.");
 }
}
'@
$hwnd=$window.MainWindowHandle
$foreground=[BkUiInput]::GetForegroundWindow()
[uint32]$foregroundOwner=0
[BkUiInput]::GetWindowThreadProcessId($foreground,[ref]$foregroundOwner) | Out-Null
$foregroundProcess=Get-Process -Id $foregroundOwner -ErrorAction SilentlyContinue
if ($null -ne $foregroundProcess -and $foregroundProcess.Path -eq $exe) {
    $window=$foregroundProcess
    $hwnd=$foreground
}
[BkUiInput]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 150
if ([BkUiInput]::GetForegroundWindow() -ne $hwnd) { throw 'Candidate is not foreground; refusing input.' }
if ($Action -eq 'click' -or $Action -eq 'scroll') {
    $rect=New-Object BkUiInput+Rect
    if (![BkUiInput]::GetWindowRect($hwnd,[ref]$rect)) {throw 'Cannot inspect candidate window.'}
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge ($rect.Right-$rect.Left) -or $Y -ge ($rect.Bottom-$rect.Top)) {throw 'Point is outside candidate window.'}
    [BkUiInput]::SetCursorPos($rect.Left+$X,$rect.Top+$Y) | Out-Null
    if ($Action -eq 'click') {
        [BkUiInput]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
        [BkUiInput]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    } else {
        if ($Wheel -eq 0 -or [Math]::Abs($Wheel) -gt 1200) {throw 'Invalid bounded scroll amount.'}
        [BkUiInput]::mouse_event(0x0800,0,0,$Wheel,[UIntPtr]::Zero)
    }
} elseif ($Action -eq 'keys') {
    $map=@{TAB='{TAB}';ENTER='{ENTER}';ESC='{ESC}';CTRL_A='^a';CLEAR='{END}{BACKSPACE 1024}';ALT_F4='%{F4}'}
    if (!$map.ContainsKey($Keys)) {throw 'Unsupported key sequence.'}
    [Windows.Forms.SendKeys]::SendWait($map[$Keys])
} elseif ($Action -eq 'text') {
    if ($TextFile) {
        $privatePath=[IO.Path]::GetFullPath($TextFile)
        if (!$privatePath.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)) {throw 'Private input must belong to this validation task.'}
        $Text=[IO.File]::ReadAllText($privatePath).TrimEnd("`r","`n")
    }
    if ($Text.Length -gt 1024 -or $Text.Contains("`r") -or $Text.Contains("`n")) {throw 'Single-line input only.'}
    # Unicode packets deliver literal text without composing it through the active keyboard layout.
    # https://learn.microsoft.com/windows/win32/api/winuser/ns-winuser-keybdinput
    [BkUiInput]::SendLiteralText($Text,$hwnd)
}
Start-Sleep -Milliseconds 300
& (Join-Path $PSScriptRoot 'inspect-windows-validation-ui.ps1') -Bundle $bundlePath -Evidence $Evidence -Action capture
