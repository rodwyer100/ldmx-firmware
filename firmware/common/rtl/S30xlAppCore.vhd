-------------------------------------------------------------------------------
-- Title      : S30XL Application Core
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- This file is part of LDMX. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of LDMX, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library surf;
use surf.StdRtlPkg.all;
use surf.AxiLitePkg.all;
use surf.AxiStreamPkg.all;

library ldmx;
use ldmx.FcPkg.all;

entity S30xlAppCore is
   generic (
      TPD_G            : time             := 1 ns;
      SIM_SPEEDUP_G    : boolean          := false;
      AXIL_BASE_ADDR_G : slv(31 downto 0) := X"00000000");
   port (
      -- FC Receiver
      -- (Looped back from fcHub IO)
      appFcRefClkP : in  sl;
      appFcRefClkN : in  sl;
      appFcRxP     : in  sl;
      appFcRxN     : in  sl;
      appFcTxP     : out sl;
      appFcTxN     : out sl;

      -- TS Interface
      tsRefClk250P : in sl;
      tsRefClk250N : in sl;
      tsDataRxP    : in sl;
      tsDataRxN    : in sl;

      -- AXI Lite interface
      axilClk         : in  sl;
      axilRst         : in  sl;
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType;

      -- DAQ Stream
      axisClk       : in  sl;
      axisRst       : in  sl;
      daqDataMaster : out AxiStreamMasterType;
      daqDataSlave  : in  AxiStreamSlaveType);
end entity S30xlAppCore;

architecture rtl of S30xlAppCore is

   -- AXI Lite
   constant AXIL_NUM_C     : integer := 4;
   constant AXIL_FC_RX_C   : integer := 0;
   constant AXIL_TS_RX_C   : integer := 1;
   constant AXIL_TS_DAQ_C  : integer := 2;
   constant AXIL_TS_TRIG_C : integer := 3;

   constant AXIL_XBAR_CONFIG_C : AxiLiteCrossbarMasterConfigArray(AXIL_NUM_C-1 downto 0) := (
      AXIL_FC_RX_C    => (
         baseAddr     => X"00000000",
         addrBits     => 20,
         connectivity => X"FFFF"),
      AXIL_TS_RX_C    => (
         baseAddr     => X"00100000",
         addrBits     => 20,
         connectivity => X"FFFF"),
      AXIL_TS_DAQ_C   => (
         baseAddr     => X"00200000",
         addrBits     => 8,
         connectivity => X"FFFF"),
      AXIL_TS_TRIG_C  => (
         baseAddr     => X"00200100",
         addrBits     => 8,
         connectivity => X"FFFF"));

   signal axilClk             : sl;
   signal axilRst             : sl;
   signal locAxilReadMasters  : AxiLiteReadMasterArray(AXIL_NUM_C-1 downto 0);
   signal locAxilReadSlaves   : AxiLiteReadSlaveArray(AXIL_NUM_C-1 downto 0)  := (others => AXI_LITE_READ_SLAVE_EMPTY_DECERR_C);
   signal locAxilWriteMasters : AxiLiteWriteMasterArray(AXIL_NUM_C-1 downto 0);
   signal locAxilWriteSlaves  : AxiLiteWriteSlaveArray(AXIL_NUM_C-1 downto 0) := (others => AXI_LITE_WRITE_SLAVE_EMPTY_DECERR_C);

   -----------------------------
   -- Fast Control clock and bus
   -----------------------------
   signal fcClk185 : sl;
   signal fcRst185 : sl;
   signal fcBus    : FastControlBusType;


begin

   -------------------------------------------------------------------------------------------------
   -- Fast Control Receiver
   -------------------------------------------------------------------------------------------------
   U_FcReceiver_1 : entity ldmx.FcReceiver
      generic map (
         TPD_G            => TPD_G,
         SIM_SPEEDUP_G    => SIM_SPEEDUP_G,
         AXIL_CLK_FREQ_G  => AXIL_CLK_FREQ_C,
         AXIL_BASE_ADDR_G => AXIL_XBAR_CFG_C(AXIL_FC_RX_C).baseAddr)
      port map (
         fcRefClk185P    => fcRefClk185P,                       -- [in]
         fcRefClk185N    => fcRefClk185N,                       -- [in]
         fcRecClkP       => open,                               -- [out]
         fcRecClkN       => open,                               -- [out]
         fcTxP           => fcTxP,                              -- [out]
         fcTxN           => fcTxN,                              -- [out]
         fcRxP           => fcRxP,                              -- [in]
         fcRxN           => fcRxN,                              -- [in]
         fcClk185        => fcClk185,                           -- [out]
         fcRst185        => fcRst185,                           -- [out]
         fcBus           => fcBus,                              -- [out]
         fcFb            => FC_FB_INIT_C,                       -- [in]
         fcBunchClk37    => open,                               -- [out]
         fcBunchRst37    => open,                               -- [out]
         axilClk         => axilClk,                            -- [in]
         axilRst         => axilRst,                            -- [in]
         axilReadMaster  => locAxilReadMasters(AXIL_FC_RX_C),   -- [in]
         axilReadSlave   => locAxilReadSlaves(AXIL_FC_RX_C),    -- [out]
         axilWriteMaster => locAxilWriteMasters(AXIL_FC_RX_C),  -- [in]
         axilWriteSlave  => locAxilWriteSlaves(AXIL_FC_RX_C));  -- [out]

   -------------------------------------------------------------------------------------------------
   -- TS Data Receiver
   -- (Data Receiver to APX)
   -------------------------------------------------------------------------------------------------
   U_TsDataRx_1 : entity ldmx.TsDataRx
      generic map (
         TPD_G            => TPD_G,
         AXIL_CLK_FREQ_G  => AXIL_CLK_FREQ_G,
         AXIL_BASE_ADDR_G => AXIL_XBAR_CFG_C(AXIL_TS_RX_C).baseAddr)
      port map (
         tsRefClkP       => tsRefClkP,                          -- [in]
         tsRefClkN       => tsRefClkN,                          -- [in]
         tsRxP           => tsRxP,                              -- [in]
         tsRxN           => tsRxN,                              -- [in]
         fcClk185        => fcClk185,                           -- [in]
         fcRst185        => fcRst185,                           -- [in]
         fcBus           => fcBus,                              -- [in]
         fcTsRxMsg       => fcTsRxMsg,                          -- [out]
         fcMsgTime       => fcMsgTime,                          -- [out]
         axilClk         => axilClk,                            -- [in]
         axilRst         => axilRst,                            -- [in]
         axilReadMaster  => locAxilReadMasters(AXIL_TS_RX_C),   -- [in]
         axilReadSlave   => locAxilReadSlaves(AXIL_TS_RX_C),    -- [out]
         axilWriteMaster => locAxilWriteMasters(AXIL_TS_RX_C),  -- [in]
         axilWriteSlave  => locAxilWriteSlaves(AXIL_TS_RX_C));  -- [out]

   -------------------------------------------------------------------------------------------------
   -- DAQ Block Shell
   -- (Probably includes Data to DAQ sender and Common block for LDMX event header/trailer)
   -------------------------------------------------------------------------------------------------

   -------------------------------------------------------------------------------------------------
   -- Trigger algorithm block
   -------------------------------------------------------------------------------------------------

   -------------------------------------------------------------------------------------------------
   -- Data to GT Sender
   -- (Encodes trigger data for transmission to GT)
   -------------------------------------------------------------------------------------------------


end architecture rtl;



