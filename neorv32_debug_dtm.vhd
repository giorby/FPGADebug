-- ================================================================================ --
-- NEORV32 OCD - RISC-V-Compatible Debug Transport Module (DTM)                     --
-- -------------------------------------------------------------------------------- --
-- Compatible to RISC-V debug spec. versions 0.13 and 1.0.                          --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              --
-- Copyright (c) NEORV32 contributors.                                              --
-- Copyright (c) 2020 - 2025 Stephan Nolting. All rights reserved.                  --
-- Copyright (c) 2026 Lorenzo Fabiani & Giorgio Biagetti.                           --
-- Licensed under the BSD-3-Clause license, see LICENSE for details.                --
-- SPDX-License-Identifier: BSD-3-Clause                                            --
-- ================================================================================ --
-- This code is based on the original NEORV32 implementatin but has been heavily    --
-- changed to support JTAG over the integrated BSCANE2 primitives on FPGA           --
-- and the synchronization logic has been rewritten to allow arbitrary TCK freq.    --
-- -------------------------------------------------------------------------------- --

library ieee;
	use ieee.std_logic_1164.all;

library neorv32;
	use neorv32.neorv32_package.all;

library unisim;
	use unisim.vcomponents.all;

entity neorv32_debug_dtm is
	generic ( -- [UNUSED!] --
		IDCODE_VERSION : std_ulogic_vector(3 downto 0);  -- version
		IDCODE_PARTID  : std_ulogic_vector(15 downto 0); -- part number
		IDCODE_MANID   : std_ulogic_vector(10 downto 0)  -- manufacturer id
	);
	port (
		global_debug_signals : out std_ulogic_vector(1 to 12);
	-- global control                --
		clk_i      : in  std_ulogic; -- global clock line
		rstn_i     : in  std_ulogic; -- global reset line, low-active
	-- JTAG connection (TAP access)  -- [UNUSED!] --
		jtag_tck_i : in  std_ulogic; -- serial clock
		jtag_tdi_i : in  std_ulogic; -- serial data input
		jtag_tdo_o : out std_ulogic; -- serial data output
		jtag_tms_i : in  std_ulogic; -- mode select
	-- debug module interface (DMI)  --
		dmi_req_o  : out dmi_req_t;  -- request
		dmi_rsp_i  : in  dmi_rsp_t   -- response
	);
end neorv32_debug_dtm;


architecture xilinx_fast of neorv32_debug_dtm is
	constant size_dtmcs_c  : natural := 32;
	constant size_dmi_c    : natural := 7+32+2; -- 7-bit address + 32-bit data + 2-bit operation/status

	-- TAP registers --
	signal dreg : std_ulogic_vector(size_dmi_c-1 downto 0); -- max size (= dmi size)

	-- misc --
	signal dmihardreset, dmireset : std_ulogic;

	-- debug module interface controller --
	signal dmi : dmi_req_t;
	signal rsp : dmi_rsp_t;
	signal busy, err : std_ulogic;

--	attribute MARK_DEBUG : string;
--	attribute MARK_DEBUG of dmi  : signal is "true";
--	attribute MARK_DEBUG of busy : signal is "true";
--	attribute MARK_DEBUG of err  : signal is "true";

	-- signal synchronizers --
	signal syncstage_busy          : std_ulogic_vector(2 downto 0);
	signal syncstage_ack           : std_ulogic_vector(1 downto 0);
	signal synchronized_busy_rise  : std_ulogic;
	signal synchronized_busy_fall  : std_ulogic;
	signal synchronized_ack        : std_ulogic;

	-- BSCANE2 output signals --
	signal bscane_capture     : std_logic;
	signal bscane_shift       : std_logic;
	signal bscane_update      : std_logic;

	signal bscane_tck         : std_logic;
	signal bscane_tms         : std_logic;
	signal bscane_tdi         : std_logic;

	signal tdo_dmi            : std_logic;
	signal bscane_sel_dmi     : std_logic;

	signal tdo_dtmcs          : std_logic;
	signal bscane_sel_dtmcs   : std_logic;

begin

	BSCANE2_inst_1 : BSCANE2
	generic map (
		JTAG_CHAIN => 1            -- IR: 0x02
	)
	port map (
		CAPTURE => bscane_capture, -- 1-bit output: CAPTURE output from TAP controller.
		SHIFT   => bscane_shift,   -- 1-bit output: SHIFT output from TAP controller.
		UPDATE  => bscane_update,  -- 1-bit output: UPDATE output from TAP controller

		TCK => bscane_tck,         -- 1-bit output: Test Clock output. Fabric connection to TAP Clock pin.
		TMS => bscane_tms,         -- 1-bit output: Test Mode Select output. Fabric connection to TAP.
		TDI => bscane_tdi,         -- 1-bit output: Test Data Input (TDI) output from TAP controller.

		SEL => bscane_sel_dmi,     -- 1-bit output: USER instruction active output.
		TDO => tdo_dmi             -- 1-bit input: Test Data Output (TDO) input for USER function.
	);

	BSCANE2_inst_2 : BSCANE2
	generic map (
		JTAG_CHAIN => 2            -- IR: 0x03
	)
	port map (
		SEL => bscane_sel_dtmcs,   -- 1-bit output: USER instruction active output.
		TDO => tdo_dtmcs           -- 1-bit input: Test Data Output (TDO) input for USER function.
	);


	-- Tap Register Access -----------------------------------------------------------------------
	-- -------------------------------------------------------------------------------------------
	reg_access : process (bscane_tck)
	begin
		if rising_edge(bscane_tck) then

			if synchronized_ack then
				busy <= '0';
			end if;

			if bscane_capture then   -------------------------------------------------------------

				if bscane_sel_dtmcs then
					dreg <= x"00000071" & "000000000";
				end if;

				if bscane_sel_dmi then
					if busy or synchronized_ack then
						err <= '1';
						dreg <= dmi.addr & x"00000000" & "11";
					else
						dreg <= dmi.addr & rsp.data & err & err;
					end if;
				end if;

			elsif bscane_shift then  -------------------------------------------------------------
				dreg <= bscane_tdi & dreg(dreg'left downto 1);

			elsif bscane_update then -------------------------------------------------------------

				if bscane_sel_dtmcs then
					if dmireset or dmihardreset then
						err <= '0';
					end if;
				end if;

				if bscane_sel_dmi then
					if busy or synchronized_ack then
						err <= '1';
					else
						dmi.addr <= dreg(40 downto 34);
						dmi.data <= dreg(33 downto 2);
						dmi.op   <= dreg(1 downto 0);
						busy     <= or dreg(1 downto 0);
					end if;
				end if;

			end if;                  -------------------------------------------------------------
		end if;
	end process reg_access;
	tdo_dtmcs <= dreg(dreg'left-(size_dtmcs_c-1));
	tdo_dmi   <= dreg(dreg'left-(size_dmi_c-1));

	-- reset control signal aliases --
	dmihardreset <= dreg((dreg'left - (size_dtmcs_c-1)) + 17);
	dmireset     <= dreg((dreg'left - (size_dtmcs_c-1)) + 16);

	-- Synchronizers -----------------------------------------------------------------------------
	-- -------------------------------------------------------------------------------------------

	DTM2DMI : process (rstn_i, clk_i)
	begin
		if not rstn_i then
			syncstage_busy <= (others => '0');
		elsif rising_edge(clk_i) then
			syncstage_busy <= busy & syncstage_busy(syncstage_busy'left downto 1);
		end if;
	end process;
	synchronized_busy_rise <= '1' when syncstage_busy(1 downto 0) = "10" else '0';
	synchronized_busy_fall <= '1' when syncstage_busy(1 downto 0) = "01" else '0';

	DMI2DTM : process (bscane_tck)
	begin
		if rising_edge(bscane_tck) then
			syncstage_ack <= rsp.ack & syncstage_ack(syncstage_ack'left downto 1);
		end if;
	end process;
	synchronized_ack <= syncstage_ack(0);

	-- Debug Module Interface --------------------------------------------------------------------
	-- -------------------------------------------------------------------------------------------
	dmi_controller : process (clk_i)
	begin
		if rising_edge(clk_i) then
			if synchronized_busy_rise then
				dmi_req_o <= dmi;
			else
				dmi_req_o.op <= dmi_req_nop_c;
			end if;
			if synchronized_busy_fall then
				rsp.ack <= '0';
			elsif dmi_rsp_i.ack then
				rsp <= dmi_rsp_i; -- rsp.ack must still go through synchronizer
			end if;
		end if;
	end process dmi_controller;

	global_debug_signals(1) <= bscane_tck;
	global_debug_signals(2) <= bscane_capture;
	global_debug_signals(3) <= bscane_shift;
	global_debug_signals(4) <= bscane_update;
	global_debug_signals(5) <= bscane_sel_dmi;
	global_debug_signals(6) <= busy;
	global_debug_signals(7) <= err;
	global_debug_signals(8) <= synchronized_ack;

	global_debug_signals( 9) <= clk_i;
	global_debug_signals(10) <= or dmi_req_o.op;
	global_debug_signals(11) <= rsp.ack;
	global_debug_signals(12) <= syncstage_busy(1);

end architecture xilinx_fast;
