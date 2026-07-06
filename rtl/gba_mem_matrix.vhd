-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- "Matrix" bank-switch mapper used by >32MB GBA Video cartridges (Shrek,
-- Shark Tale, etc -- see big_rom_active in memorymux_extern.vhd for the
-- other half of this feature, the plain >32MB linear addressing). This part
-- covers the mapper's own quirk: an 8KB window at the very start of cart
-- space (16 slots of 512 bytes) that game code can repoint at any 512-byte
-- chunk of the full ROM via a small command register block.
--
-- Ported from mGBA's src/gba/cart/matrix.c (GBAMatrixReset/GBAMatrixWrite/
-- GBAMatrixWrite16), the reference implementation this was designed against.
-- mGBA implements a remap as an actual memcpy into its ROM buffer; this is a
-- hardware-native equivalent instead: each slot stores the already-resolved
-- absolute SDRAM address of its physical chunk (computed once, at commit
-- time, folding in whichever 32MB half of Softmap_GBA_Gamerom_ADDR /
-- Softmap_GBA_Gamerom_Ext_ADDR that chunk's paddr falls in), so a cart read
-- inside the window is just a table lookup, no data movement.
--
-- Register block, only reachable via the plain 0x8 cart mirror (matches
-- mGBA's GBA_REGION_ROM0-only check), sub-register = cart_addr(5 downto 2):
--   trigger: cart_addr(24)='0', cart_addr(23)='1', cart_addr(22 downto 9)=0, cart_addr(8)='1'
--            (this is "cart_addr and 0x01FFFF00 = 0x00800100" from the reference, spelled out bit by bit)
--   0x00 cmd    write 0x0001 or 0x0011 (low 16 bits) commits the staged paddr/vaddr/size as a new mapping
--   0x04 paddr  physical (whole-ROM) byte offset of the source data, up to 64MB
--   0x08 vaddr  destination byte offset within the 8KB window; only bits [12:9] may be
--               nonzero (16 slots x 512 bytes) or the commit is silently rejected
--   0x0C size   byte count in 512-byte units (stored value << 9); 0 is rejected
-- 16-bit writes (cart_be32 covering only one half) preserve the other half of
-- whichever register they target.
entity gba_mem_matrix is
   generic
   (
      Softmap_GBA_Gamerom_ADDR     : integer;
      Softmap_GBA_Gamerom_Ext_ADDR : integer
   );
   port
   (
      clk1x            : in  std_logic;
      reset            : in  std_logic;
      active           : in  std_logic; -- big_rom_active

      cart_ena         : in  std_logic;
      cart_rnw         : in  std_logic;
      cart_addr        : in  std_logic_vector(27 downto 0);
      cart_writedata32 : in  std_logic_vector(31 downto 0);
      cart_be32        : in  std_logic_vector(3 downto 0);

      -- read-side override for memorymux_extern: when remap_hit='1' for the
      -- cart_addr it's currently servicing, use remap_sdram_addr instead of
      -- its own rom_base_addr + offset computation.
      remap_hit        : out std_logic;
      remap_sdram_addr : out std_logic_vector(26 downto 0)
   );
end entity;

architecture arch of gba_mem_matrix is

   constant NUM_MAPPINGS   : integer := 16;
   constant SLOT_BYTES : integer := 512;

   type t_mappings is array(0 to NUM_MAPPINGS - 1) of unsigned(26 downto 0);
   signal mappings : t_mappings := (others => (others => '0'));

   signal reg_paddr : unsigned(25 downto 0) := (others => '0'); -- byte offset into the full ROM, up to 64MB
   signal reg_vaddr : unsigned(22 downto 0) := (others => '0'); -- byte offset into the 8KB window
   signal reg_size  : unsigned(31 downto 0) := to_unsigned(8, 32); -- raw register value, 512B units; shifted <<9 (to bytes) only at commit time, matching the reference (size = value << 9)

   signal write_hit : std_logic;
   signal subreg     : std_logic_vector(3 downto 0);

   -- physical byte offset (into the up-to-64MB ROM) -> resolved SDRAM address
   function resolve(phys_offset : unsigned(25 downto 0)) return unsigned is
   begin
      if (phys_offset(25) = '1') then
         return to_unsigned(Softmap_GBA_Gamerom_Ext_ADDR, 27) + resize(phys_offset, 27);
      else
         return to_unsigned(Softmap_GBA_Gamerom_ADDR, 27) + resize(phys_offset, 27);
      end if;
   end function;

begin

   -- trigger check spelled out bit-by-bit: cart_addr and 0x01FFFF00 = 0x00800100
   write_hit <= '1' when (active = '1' and cart_ena = '1' and cart_rnw = '0' and
                          cart_addr(27 downto 24) = x"8" and
                          cart_addr(24)          = '0' and
                          cart_addr(23)          = '1' and
                          cart_addr(22 downto 9) = 14x"0000" and
                          cart_addr(8)           = '1') else '0';
   subreg <= cart_addr(5 downto 2);

   process (clk1x)
      variable v_start : integer range 0 to NUM_MAPPINGS - 1;
      variable v_count : integer range 0 to NUM_MAPPINGS;
      variable v_valid : boolean;
   begin
      if (rising_edge(clk1x)) then

         if (reset = '1') then
            -- matches GBAMatrixReset(): two back-to-back 4KB (8-slot) remaps,
            -- {paddr=0,vaddr=0} then {paddr=0x200,vaddr=0x1000}, both against
            -- physical offset 0 (so both always resolve through the Ext_ADDR-
            -- less "normal" base -- correct, since these bootstrap mappings
            -- only ever point at the very start of the ROM).
            for i in 0 to 7 loop
               mappings(i)     <= resolve(to_unsigned(i * SLOT_BYTES, 26));
               mappings(i + 8) <= resolve(to_unsigned(512 + i * SLOT_BYTES, 26));
            end loop;
            reg_paddr <= (others => '0');
            reg_vaddr <= (others => '0');
            reg_size  <= to_unsigned(8, 32); -- 8 units x 512B = 4096 bytes, matching the reference default

         elsif (write_hit = '1') then
            case (subreg) is

               when "0000" => -- cmd
                  if (cart_be32(1) = '1' or cart_be32(0) = '1') then
                     if (cart_writedata32(15 downto 0) = x"0001" or cart_writedata32(15 downto 0) = x"0011") then
                        -- reg_size is raw 512B units here; the reference's "size = value << 9" shift
                        -- is applied right here at commit time instead, on the reconstructed register
                        v_valid := (reg_vaddr(8 downto 0) = 9x"000") and (reg_size /= 0) and
                                   (reg_size <= to_unsigned(NUM_MAPPINGS, 32)) and
                                   (to_integer(reg_vaddr(12 downto 9)) + to_integer(reg_size(3 downto 0)) <= NUM_MAPPINGS);
                        if (v_valid) then
                           v_start := to_integer(reg_vaddr(12 downto 9));
                           v_count := to_integer(reg_size(3 downto 0));
                           for i in 0 to NUM_MAPPINGS - 1 loop
                              if (i < v_count) then
                                 mappings((v_start + i) mod NUM_MAPPINGS) <= resolve(reg_paddr + to_unsigned(i * SLOT_BYTES, 26));
                              end if;
                           end loop;
                        end if;
                     end if;
                  end if;

               when "0001" => -- paddr
                  if (cart_be32(3) = '1' or cart_be32(2) = '1') then reg_paddr(25 downto 16) <= unsigned(cart_writedata32(25 downto 16)); end if;
                  if (cart_be32(1) = '1' or cart_be32(0) = '1') then reg_paddr(15 downto  0) <= unsigned(cart_writedata32(15 downto  0)); end if;

               when "0010" => -- vaddr
                  if (cart_be32(3) = '1' or cart_be32(2) = '1') then reg_vaddr(22 downto 16) <= unsigned(cart_writedata32(22 downto 16)); end if;
                  if (cart_be32(1) = '1' or cart_be32(0) = '1') then reg_vaddr(15 downto  0) <= unsigned(cart_writedata32(15 downto  0)); end if;

               when "0011" => -- size (raw value, in 512B units; shift happens at commit time above)
                  if (cart_be32(3) = '1' or cart_be32(2) = '1') then reg_size(31 downto 16) <= unsigned(cart_writedata32(31 downto 16)); end if;
                  if (cart_be32(1) = '1' or cart_be32(0) = '1') then reg_size(15 downto  0) <= unsigned(cart_writedata32(15 downto  0)); end if;

               when others =>
                  null;

            end case;
         end if;

      end if;
   end process;

   -- read-side lookup: combinational on the same cart_addr memorymux_extern
   -- is about to register into its own cart_addr_1, so both land on the
   -- translated value at the same cycle.
   remap_hit <= '1' when (active = '1' and cart_ena = '1' and cart_rnw = '1' and
                          cart_addr(27 downto 24) = x"8" and
                          unsigned(cart_addr(23 downto 13)) = 0) else '0';

   remap_sdram_addr <= std_logic_vector(mappings(to_integer(unsigned(cart_addr(12 downto 9)))) + resize(unsigned(cart_addr(8 downto 0)), 27));

end architecture;
