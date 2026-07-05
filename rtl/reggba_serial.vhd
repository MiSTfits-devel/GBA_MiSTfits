library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

package pReg_gba_serial is

   -- range 0x120 .. 0x15A (except 130..133)
   --   (                                 adr      upper    lower    size   default   accesstype)                                     
   constant SIODATA32   : regmap_type := (16#120#,  31,      0,        1,        0,   readwrite); -- SIO Data (Normal-32bit Mode; shared with below)   4    R/W 
   constant SIOMULTI0   : regmap_type := (16#120#,  15,      0,        1,        0,   readwrite); -- SIO Data 0 (Parent)    (Multi-Player Mode)        2    R/W 
   -- NOTE: gba_memorymux presents the proc bus WORD-ALIGNED (low 2 address
   -- bits forced to "00", gba_memorymux.vhd gb_bus_out.adr) and eProcReg_gba
   -- matches addresses exactly. A register in the upper half of its word
   -- must be declared at the WORD address with bits 31..16 (the convention
   -- reggba_timer.vhd's TMxCNT_H follow) -- a declaration like
   -- (16#122#, 15, 0) is UNREACHABLE from the CPU: writes never land, reads
   -- return 0 in that half. Exactly that mistake on SIOMULTI1/3,
   -- SIOMLT_SEND/SIODATA8 and IR silently broke the 2P link (send data was
   -- never written -> only NO_DATA frames on the wire; SIOMULTI3 read as
   -- 0x0000 -> gba-link-connection counted a phantom 3rd player). The unit
   -- benches missed it because their hand-rolled bus models presented exact
   -- halfword addresses -- keep bench bus models word-aligned like the mux.
   constant SIOMULTI1   : regmap_type := (16#120#,  31,     16,        1,        0,   readwrite); -- SIO Data 1 (1st Child) (Multi-Player Mode)        2    R/W
   constant SIOMULTI2   : regmap_type := (16#124#,  15,      0,        1,        0,   readwrite); -- SIO Data 2 (2nd Child) (Multi-Player Mode)        2    R/W
   constant SIOMULTI3   : regmap_type := (16#124#,  31,     16,        1,        0,   readwrite); -- SIO Data 3 (3rd Child) (Multi-Player Mode)        2    R/W
   constant SIOCNT      : regmap_type := (16#128#,  15,      0,        1,        0,   readwrite); -- SIO Control Register                              2    R/W
   constant SIOMLT_SEND : regmap_type := (16#128#,  31,     16,        1,        0,   readwrite); -- SIO Data (Local of MultiPlayer; shared below)     2    R/W
   constant SIODATA8    : regmap_type := (16#128#,  31,     16,        1,        0,   readwrite); -- SIO Data (Normal-8bit and UART Mode)              2    R/W
 --constant -           : regmap_type := (16#12C#,  15,      0,        1,        0,   readwrite); -- Not used                                               -
   constant RCNT        : regmap_type := (16#134#,  15,      0,        1,        0,   readwrite); -- SIO Mode Select/General Purpose Data              2    R/W
   constant IR          : regmap_type := (16#134#,  31,     16,        1,        0,   readwrite); -- Ancient - Infrared Register (Prototypes only)     -    -
 --constant -           : regmap_type := (16#138#,  15,      0,        1,        0,   readwrite); -- Not used                                               -   
   constant JOYCNT      : regmap_type := (16#140#,  15,      0,        1,        0,   readwrite); -- SIO JOY Bus Control                               2    R/W 
 --constant -           : regmap_type := (16#142#,  15,      0,        1,        0,   readwrite); -- Not used                                               -   
   constant JOY_RECV    : regmap_type := (16#150#,  31,      0,        1,        0,   readwrite); -- SIO JOY Bus Receive Data                          4    R/W 
   constant JOY_TRANS   : regmap_type := (16#154#,  31,      0,        1,        0,   readwrite); -- SIO JOY Bus Transmit Data                         4    R/W 
   constant JOYSTAT     : regmap_type := (16#158#,  15,      0,        1,        0,   readwrite); -- SIO JOY Bus Receive Status                        2    R/? 
   
end package;
