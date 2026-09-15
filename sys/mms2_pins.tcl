# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Pin constraints for the Multisystem2 expansion bus, used by the GBA_MMS2
# revision. Kept in a sourced .tcl next to sys.tcl rather than inline in the
# qsf because that is the route the framework's own pin constraints take and
# the one Quartus 17 reliably honours for IO_STANDARD.
#
# Every pin here is a stock DE10-Nano function that the Multisystem2 routes to
# its expansion header instead - see docs/mms2_cart.md for the cartridge-side
# meaning of each bit.

set_location_assignment PIN_AH8 -to MMS_BUS[0]
set_location_assignment PIN_AG8 -to MMS_BUS[1]
set_location_assignment PIN_U13 -to MMS_BUS[2]
set_location_assignment PIN_U14 -to MMS_BUS[3]
set_location_assignment PIN_AG9 -to MMS_BUS[4]
set_location_assignment PIN_AG10 -to MMS_BUS[5]
set_location_assignment PIN_AF13 -to MMS_BUS[6]
set_location_assignment PIN_AG13 -to MMS_BUS[7]
set_location_assignment PIN_U9 -to MMS_BUS[8]
set_location_assignment PIN_AD4 -to MMS_BUS[9]
set_location_assignment PIN_V10 -to MMS_BUS[10]
set_location_assignment PIN_AC4 -to MMS_BUS[11]
set_location_assignment PIN_W15 -to MMS_BUS[12]
set_location_assignment PIN_AA24 -to MMS_BUS[13]
set_location_assignment PIN_V16 -to MMS_BUS[14]
set_location_assignment PIN_V15 -to MMS_BUS[15]
set_location_assignment PIN_AF26 -to MMS_BUS[16]
set_location_assignment PIN_AE26 -to MMS_BUS[17]
set_location_assignment PIN_Y16 -to MMS_BUS[18]
set_location_assignment PIN_AA23 -to MMS_BUS[19]
set_location_assignment PIN_AH17 -to MMS_BUS[20]
set_location_assignment PIN_AH16 -to MMS_BUS[21]
set_location_assignment PIN_AH7 -to MMS_BUS[22]
set_location_assignment PIN_AF25 -to MMS_BUS[23]
set_location_assignment PIN_AF23 -to MMS_BUS[24]
set_location_assignment PIN_AD26 -to MMS_BUS[25]
set_location_assignment PIN_AF28 -to MMS_BUS[26]
set_location_assignment PIN_AH26 -to MMS_BUS[27]
set_location_assignment PIN_AF27 -to MMS_BUS[28]

set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to MMS_BUS[*]

# lowest drive strength that works, for EMC (Heber's own recommendation)
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to MMS_BUS[*]

# bus hold would fight the cartridge and the level shifters on turnaround
set_instance_assignment -name ENABLE_BUS_HOLD_CIRCUITRY OFF -to MMS_BUS[*]
