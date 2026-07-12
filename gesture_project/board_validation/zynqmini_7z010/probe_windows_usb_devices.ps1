$patterns = 'Xilinx|Digilent|JTAG|USB Serial|FTDI|UART|COM|Cypress|Zynq'
$vidPatterns = 'VID_0403|VID_03FD|VID_1443'

Get-PnpDevice -PresentOnly |
  Where-Object {
    $_.FriendlyName -match $patterns -or
    $_.InstanceId -match $vidPatterns
  } |
  Select-Object Status, Class, FriendlyName, InstanceId |
  Format-Table -AutoSize
