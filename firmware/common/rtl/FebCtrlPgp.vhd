-------------------------------------------------------------------------------
-- Title      : Coulter PGP 
-------------------------------------------------------------------------------
-- File       : FebCtrlPgp.vhd
-- Author     : Benjamin Reese  <bareese@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- This file is part of Coulter. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of Coulter, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

library unisim;
use unisim.vcomponents.all;


library surf;
use surf.StdRtlPkg.all;
use surf.Gtp7CfgPkg.all;
use surf.Pgp2bPkg.all;
use surf.AxiLitePkg.all;
use surf.AxiStreamPkg.all;
use surf.SsiPkg.all;


library hps_daq;
use hps_daq.HpsPkg.all;

entity FebCtrlPgp is
   generic (
      TPD_G            : time             := 1 ns;
      SIMULATION_G     : boolean          := false;
      FIXED_LATENCY_G  : boolean          := false;
      AXIL_BASE_ADDR_G : slv(31 downto 0) := (others => '0');
      SEM_EN_G         : boolean          := true;
      PRBS_EN_G        : boolean          := true);
   port (
      -- GTX 7 Ports
      gtClkP           : in  sl;
      gtClkN           : in  sl;
      gtRxP            : in  sl;
      gtRxN            : in  sl;
      gtTxP            : out sl;
      gtTxN            : out sl;
      stableClkOut     : out sl;
      stableRstOut     : out sl;
      -- Output status
      rxLinkReady      : out sl;
      txLinkReady      : out sl;
      frameRx          : out sl;
      frameRxErr       : out sl;
      cellError        : out sl;
      linkDown         : out sl;
      linkError        : out sl;
      -- Recovered clock and trigger
      distClk          : out sl;
      distRst          : out sl;
      distOpCodeEn     : out sl;
      distOpCode       : out slv(7 downto 0);
      -- AXIL Interface
      axilClk          : out sl;
      axilRst          : out sl;
      mAxilReadMaster  : out AxiLiteReadMasterType;
      mAxilReadSlave   : in  AxiLiteReadSlaveType;
      mAxilWriteMaster : out AxiLiteWriteMasterType;
      mAxilWriteSlave  : in  AxiLiteWriteSlaveType;
      -- Slave AXIL interface for PGP and GTP
      sAxilReadMaster  : in  AxiLiteReadMasterType;
      sAxilReadSlave   : out AxiLiteReadSlaveType;
      sAxilWriteMaster : in  AxiLiteWriteMasterType;
      sAxilWriteSlave  : out AxiLiteWriteSlaveType;
      -- SEM Streaming Interface
      semRxAxisMaster  : out AxiStreamMasterType;
      semRxAxisSlave   : in  AxiStreamSlaveType  := AXI_STREAM_SLAVE_INIT_C;
      semTxAxisMaster  : in  AxiStreamMasterType := AXI_STREAM_MASTER_INIT_C;
      semTxAxisSlave   : out AxiStreamSlaveType);

end FebCtrlPgp;

architecture rtl of FebCtrlPgp is

   constant REFCLK_FREQ_C : real            := 125.0e6;
   constant LINE_RATE_C   : real            := 2.5e9;
   constant GTP_CFG_C     : Gtp7QPllCfgType := getGtp7QPllCfg(REFCLK_FREQ_C, LINE_RATE_C);

   signal stableClk : sl;
   signal stableRst : sl := '0';
--   signal powerUpRst : sl;

   signal pgpTxClk     : sl;
   signal pgpTxRst     : sl;
   signal pgpRxClk     : sl;
   signal pgpRxRst     : sl;
   signal pgpTxMasters : AxiStreamMasterArray(3 downto 0) := (others => AXI_STREAM_MASTER_INIT_C);
   signal pgpTxSlaves  : AxiStreamSlaveArray(3 downto 0)  := (others => AXI_STREAM_SLAVE_INIT_C);
   signal pgpRxMasters : AxiStreamMasterArray(3 downto 0) := (others => AXI_STREAM_MASTER_INIT_C);
   signal pgpRxSlaves  : AxiStreamSlaveArray(3 downto 0)  := (others => AXI_STREAM_SLAVE_FORCE_C);
   signal pgpRxCtrl    : AxiStreamCtrlArray(3 downto 0)   := (others => AXI_STREAM_CTRL_UNUSED_C);
   signal pgpRxIn      : Pgp2bRxInType;
   signal pgpRxOut     : Pgp2bRxOutType;
   signal pgpTxIn      : Pgp2bTxInType;
   signal pgpTxOut     : Pgp2bTxOutType;

   -- AXIL
   constant AXIL_MASTERS_C      : integer := 4;
   constant PGP_AXI_INDEX_C     : integer := 0;
   constant GTP_AXI_INDEX_C     : integer := 1;
   constant PRBS_RX_AXI_INDEX_C : integer := 2;
   constant PRBS_TX_AXI_INDEX_C : integer := 3;

   constant AXIL_XBAR_CFG_C : AxiLiteCrossbarMasterConfigArray(AXIL_MASTERS_C-1 downto 0) := (
      PGP_AXI_INDEX_C     => (
         baseAddr         => AXIL_BASE_ADDR_G,
         addrBits         => 8,
         connectivity     => X"0001"),
      GTP_AXI_INDEX_C     => (
         baseAddr         => AXIL_BASE_ADDR_G + X"10000",
         addrBits         => 16,
         connectivity     => X"0001"),
      PRBS_RX_AXI_INDEX_C => (
         baseAddr         => AXIL_BASE_ADDR_G + X"20000",
         addrBits         => 12,
         connectivity     => X"0001"),
      PRBS_TX_AXI_INDEX_C => (
         baseAddr         => AXIL_BASE_ADDR_G + X"21000",
         addrBits         => 8,
         connectivity     => X"0001"));

   signal locAxilReadMasters  : AxiLiteReadMasterArray(AXIL_MASTERS_C-1 downto 0);
   signal locAxilReadSlaves   : AxiLiteReadSlaveArray(AXIL_MASTERS_C-1 downto 0);
   signal locAxilWriteMasters : AxiLiteWriteMasterArray(AXIL_MASTERS_C-1 downto 0);
   signal locAxilWriteSlaves  : AxiLiteWriteSlaveArray(AXIL_MASTERS_C-1 downto 0);

begin

   -- Map to signals out
   rxLinkReady  <= pgpRxOut.linkReady;
   txLinkReady  <= pgpTxOut.linkReady;
   frameRx      <= pgpRxOut.frameRx;
   frameRxErr   <= pgpRxOut.frameRxErr;
   cellError    <= pgpRxOut.cellError;
   linkDown     <= pgpRxOut.linkDown;
   linkError    <= pgpRxOut.linkError;
   distClk      <= pgpRxClk;
   distRst      <= pgpRxRst;
   distOpCodeEn <= pgpRxOut.opCodeEn;
   distOpCode   <= pgpRxOut.opCode;
   axilClk      <= pgpTxClk;
   axilRst      <= pgpTxRst;
   stableClkOut <= stableClk;
   stableRstOut <= stableRst;

   -------------------------------------------------------------------------------------------------
   -- AXI Lite crossbar
   -------------------------------------------------------------------------------------------------
   U_AxiLiteCrossbar_1 : entity surf.AxiLiteCrossbar
      generic map (
         TPD_G              => TPD_G,
         NUM_SLAVE_SLOTS_G  => 1,
         NUM_MASTER_SLOTS_G => AXIL_MASTERS_C,
         DEC_ERROR_RESP_G   => AXI_RESP_DECERR_C,
         MASTERS_CONFIG_G   => AXIL_XBAR_CFG_C,
         DEBUG_G            => true)
      port map (
         axiClk              => pgpTxClk,             -- [in]
         axiClkRst           => pgpTxRst,             -- [in]
         sAxiWriteMasters(0) => sAxilWriteMaster,     -- [in]
         sAxiWriteSlaves(0)  => sAxilWriteSlave,      -- [out]
         sAxiReadMasters(0)  => sAxilReadMaster,      -- [in]
         sAxiReadSlaves(0)   => sAxilReadSlave,       -- [out]
         mAxiWriteMasters    => locAxilWriteMasters,  -- [out]
         mAxiWriteSlaves     => locAxilWriteSlaves,   -- [in]
         mAxiReadMasters     => locAxilReadMasters,   -- [out]
         mAxiReadSlaves      => locAxilReadSlaves);   -- [in]

   -------------------------------
   --       PGP Core            --
   -------------------------------
   NO_SIM : if (SIMULATION_G = false) generate
      FIXED_LATENCY_PGP : if (FIXED_LATENCY_G) generate
         U_Pgp2bGtp7FixedLatWrapper_1 : entity surf.Pgp2bGtp7FixedLatWrapper
            generic map (
               TPD_G                   => TPD_G,
               SIM_GTRESET_SPEEDUP_G   => SIMULATION_G,
               SIM_VERSION_G           => "2.0",
               SIMULATION_G            => SIMULATION_G,
               VC_INTERLEAVE_G         => 0,
               PAYLOAD_CNT_TOP_G       => 7,
               NUM_VC_EN_G             => 3,
               AXIL_BASE_ADDR_G        => AXIL_XBAR_CFG_C(GTP_AXI_INDEX_C).baseAddr,
               EXT_RST_POLARITY_G      => '1',
               TX_ENABLE_G             => true,
               RX_ENABLE_G             => true,
               TX_CM_EN_G              => true,
               TX_CM_TYPE_G            => "MMCM",
               TX_CM_CLKIN_PERIOD_G    => 8.0,
               TX_CM_DIVCLK_DIVIDE_G   => 1,
               TX_CM_CLKFBOUT_MULT_F_G => 8.0,                           --7.625,
               TX_CM_CLKOUT_DIVIDE_F_G => 8.0,                           --7.625,
               RX_CM_EN_G              => false,
               RX_CM_TYPE_G            => "MMCM",
               RX_CM_CLKIN_PERIOD_G    => 8.0,
               RX_CM_DIVCLK_DIVIDE_G   => 1,
               RX_CM_CLKFBOUT_MULT_F_G => 12.75,
               RX_CM_CLKOUT_DIVIDE_F_G => 12.75,
               PMA_RSV_G               => X"00000333",
--             RX_OS_CFG_G             => "0001111110000",
               RXCDR_CFG_G             => X"0001107FE206021081010",      --X"0000107FE206001041010",
--             RXDFEXYDEN_G            => RXDFEXYDEN_G,
               STABLE_CLK_SRC_G        => "gtClk0",
               TX_REFCLK_SRC_G         => "gtClk0",
               TX_USER_CLK_SRC_G       => "txOutClk",
               RX_REFCLK_SRC_G         => "gtClk0",
               TX_PLL_CFG_G            => GTP_CFG_C,
               RX_PLL_CFG_G            => GTP_CFG_C,
               TX_PLL_G                => "PLL0",
               RX_PLL_G                => "PLL1")
            port map (
               stableClkIn     => '0',  -- [in]
               extRst          => '0',  -- [in]
               txPllLock       => open,      -- [out]
               rxPllLock       => open,      -- [out]
               pgpTxClkOut     => pgpTxClk,  -- [out]
               pgpTxRstOut     => pgpTxRst,  -- [out]
               pgpRxClkOut     => pgpRxClk,  -- [out] -- Fixed Latency recovered clock
               pgpRxRstOut     => pgpRxRst,  -- [out]
               stableClkOut    => stableClk,                             -- [out]
               pgpRxIn         => pgpRxIn,   -- [in]
               pgpRxOut        => pgpRxOut,  -- [out]
               pgpTxIn         => pgpTxIn,   -- [in]
               pgpTxOut        => pgpTxOut,  -- [out]
               pgpTxMasters    => pgpTxMasters,                          -- [in]
               pgpTxSlaves     => pgpTxSlaves,                           -- [out]
               pgpRxMasters    => pgpRxMasters,                          -- [out]
               pgpRxCtrl       => pgpRxCtrl,                             -- [in]
               gtClk0P         => gtClkP,    -- [in]
               gtClk0N         => gtClkN,    -- [in]
               gtTxP           => gtTxP,     -- [out]
               gtTxN           => gtTxN,     -- [out]
               gtRxP           => gtRxP,     -- [in]
               gtRxN           => gtRxN,     -- [in]
               axilClk         => pgpTxClk,  -- [in]
               axilRst         => pgpTxRst,  -- [in]
               axilReadMaster  => locAxilReadMasters(GTP_AXI_INDEX_C),   -- [in]
               axilReadSlave   => locAxilReadSlaves(GTP_AXI_INDEX_C),    -- [out]
               axilWriteMaster => locAxilWriteMasters(GTP_AXI_INDEX_C),  -- [in]
               axilWriteSlave  => locAxilWriteSlaves(GTP_AXI_INDEX_C));  -- [out]
      end generate FIXED_LATENCY_PGP;

      VARIABLE_LATENCY_PGP : if (FIXED_LATENCY_G = false) generate

         PwrUpRst_Inst : entity surf.PwrUpRst
            generic map (
               TPD_G          => TPD_G,
               SIM_SPEEDUP_G  => SIMULATION_G,
               IN_POLARITY_G  => '1',
               OUT_POLARITY_G => '1')
            port map (
               arst   => '0',
               clk    => stableClk,
               rstOut => stableRst);


         U_Pgp2bGtp7VarLatWrapper_1 : entity surf.Pgp2bGtp7VarLatWrapper
            generic map (
               TPD_G                => TPD_G,
               SIMULATION_G         => SIMULATION_G,
               CLKIN_PERIOD_G       => 8.0,
               DIVCLK_DIVIDE_G      => 1,
               CLKFBOUT_MULT_F_G    => 8.0,
               CLKOUT0_DIVIDE_F_G   => 8.0,
               QPLL_REFCLK_SEL_G    => "001",
               QPLL_FBDIV_IN_G      => GTP_CFG_C.QPLL_FBDIV_G,           --4
               QPLL_FBDIV_45_IN_G   => GTP_CFG_C.QPLL_FBDIV_45_G,        --5
               QPLL_REFCLK_DIV_IN_G => GTP_CFG_C.QPLL_REFCLK_DIV_G,      --1
               RXOUT_DIV_G          => GTP_CFG_C.OUT_DIV_G,              --2
               TXOUT_DIV_G          => GTP_CFG_C.OUT_DIV_G,              --2
               RX_CLK25_DIV_G       => GTP_CFG_C.CLK25_DIV_G,
               TX_CLK25_DIV_G       => GTP_CFG_C.CLK25_DIV_G,
--             RX_OS_CFG_G => X"0000010000000",
               RXCDR_CFG_G          => X"0001107FE206021081010",         --X"0000107FE206001041010",
               RX_ENABLE_G          => true,
               TX_ENABLE_G          => true,
               PAYLOAD_CNT_TOP_G    => 7,
               VC_INTERLEAVE_G      => 0,
               NUM_VC_EN_G          => 4)
            port map (
               extRst          => stableRst,                             -- [in]
               pgpClk          => pgpTxClk,                              -- [out]
               pgpRst          => pgpTxRst,                              -- [out]
               stableClk       => stableClk,                             -- [out]
               pgpTxIn         => pgpTxIn,                               -- [in]
               pgpTxOut        => pgpTxOut,                              -- [out]
               pgpRxIn         => pgpRxIn,                               -- [in]
               pgpRxOut        => pgpRxOut,                              -- [out]
               pgpTxMasters    => pgpTxMasters,                          -- [in]
               pgpTxSlaves     => pgpTxSlaves,                           -- [out]
               pgpRxMasters    => pgpRxMasters,                          -- [out]
               pgpRxCtrl       => pgpRxCtrl,                             -- [in]
               gtClkP          => gtClkP,                                -- [in]
               gtClkN          => gtClkN,                                -- [in]
               gtTxP           => gtTxP,                                 -- [out]
               gtTxN           => gtTxN,                                 -- [out]
               gtRxP           => gtRxP,                                 -- [in]
               gtRxN           => gtRxN,                                 -- [in]
               axilClk         => pgpTxClk,                              -- [in]
               axilRst         => pgpTxRst,                              -- [in]
               axilReadMaster  => locAxilReadMasters(GTP_AXI_INDEX_C),   -- [in]
               axilReadSlave   => locAxilReadSlaves(GTP_AXI_INDEX_C),    -- [out]
               axilWriteMaster => locAxilWriteMasters(GTP_AXI_INDEX_C),  -- [in]
               axilWriteSlave  => locAxilWriteSlaves(GTP_AXI_INDEX_C));  -- [out]

         pgpRxClk <= pgpTxClk;
         pgpRxRst <= pgpTxRst;

      end generate VARIABLE_LATENCY_PGP;
   end generate NO_SIM;

   SIMULATION_PGP : if (SIMULATION_G) generate
      signal txOutRst  : sl;
      signal txOutClk  : sl;
      signal txOutClkP : sl;
      signal txOutClkN : sl;
   begin
      -- Clock manager to simulate GTP gtrefclk->txoutclk | 156.25->125
      U_SIM_GTP_PLL : entity surf.ClockManager7
         generic map (
            TPD_G              => TPD_G,
            TYPE_G             => "MMCM",
            INPUT_BUFG_G       => false,
            FB_BUFG_G          => true,
            NUM_CLOCKS_G       => 1,
            BANDWIDTH_G        => "OPTIMIZED",
            CLKIN_PERIOD_G     => 6.4,
            DIVCLK_DIVIDE_G    => 5,
            CLKFBOUT_MULT_F_G  => 32.0,
            CLKOUT0_DIVIDE_F_G => 8.0)
         port map (
            clkIn     => gtClkP,
            rstIn     => stableRst,
            clkOut(0) => txOutClk,
            rstOut(0) => txOutRst);

      OBUFDS_1 : OBUFDS
         port map (
            i  => txOutClk,
            o  => txOutClkP,
            ob => txOutClkN);


      U_RoguePgpSim_1 : entity work.RoguePgpSim
         generic map (
            TPD_G       => TPD_G,
            FIXED_LAT_G => true,
            USER_ID_G   => 1,
            NUM_VC_EN_G => 4)
         port map (
            refClkP      => txOutClkP,     -- [in]
            refClkM      => txOutClkN,     -- [in]
            pgpTxClk     => pgpTxClk,      -- [out]
            pgpTxRst     => pgpTxRst,      -- [out]
            pgpTxIn      => pgpTxIn,       -- [in]
            pgpTxOut     => pgpTxOut,      -- [out]
            pgpTxMasters => pgpTxMasters,  -- [in]
            pgpTxSlaves  => pgpTxSlaves,   -- [out]
            pgpRxClk     => pgpRxClk,      -- [out]
            pgpRxRst     => pgpRxRst,      -- [out]
            pgpRxIn      => pgpRxIn,       -- [in]
            pgpRxOut     => pgpRxOut,      -- [out]
            pgpRxMasters => pgpRxMasters,  -- [out]
            pgpRxSlaves  => pgpRxSlaves);  -- [in]
   end generate SIMULATION_PGP;

   pgpRxIn.flush    <= '0';
   pgpRxIn.resetRx  <= '0';
   pgpRxIn.loopback <= "000";



   -------------------------------------------------------------------------------------------------
   -- PGP monitor
   -------------------------------------------------------------------------------------------------
   CntlPgp2bAxi : entity surf.Pgp2bAxi
      generic map (
         TPD_G              => TPD_G,
         COMMON_TX_CLK_G    => true,
         COMMON_RX_CLK_G    => (FIXED_LATENCY_G = false),
         WRITE_EN_G         => false,
         AXI_CLK_FREQ_G     => 125.0E+6,
         STATUS_CNT_WIDTH_G => 32,
         ERROR_CNT_WIDTH_G  => 16)
      port map (
         pgpTxClk        => pgpTxClk,                              -- [in]
         pgpTxClkRst     => pgpTxRst,                              -- [in]
         pgpTxIn         => pgpTxIn,                               -- [out]
         pgpTxOut        => pgpTxOut,                              -- [in]
         pgpRxClk        => pgpRxClk,                              -- [in]
         pgpRxClkRst     => pgpRxRst,                              -- [in]
         --pgpRxIn         => pgpRxIn,                               -- [out]
         pgpRxOut        => pgpRxOut,                              -- [in]
         axilClk         => pgpTxClk,                              -- [in]
         axilRst         => pgpTxRst,                              -- [in]
         axilReadMaster  => locAxilReadMasters(PGP_AXI_INDEX_C),   -- [in]
         axilReadSlave   => locAxilReadSlaves(PGP_AXI_INDEX_C),    -- [out]
         axilWriteMaster => locAxilWriteMasters(PGP_AXI_INDEX_C),  -- [in]
         axilWriteSlave  => locAxilWriteSlaves(PGP_AXI_INDEX_C));  -- [out]

-- Lane 0, VC0 RX/TX, Register access control        
   U_Vc0AxiMasterRegisters : entity surf.SrpV3AxiLite
      generic map (
         TPD_G               => TPD_G,
         SLAVE_READY_EN_G    => SIMULATION_G,
         GEN_SYNC_FIFO_G     => false,
         AXIL_CLK_FREQ_G     => 125.0e6,
         AXI_STREAM_CONFIG_G => SSI_PGP2B_CONFIG_C
         )
      port map (
         -- Streaming Slave (Rx) Interface (sAxisClk domain) 
         sAxisClk         => pgpRxClk,
         sAxisRst         => pgpRxRst,
         sAxisMaster      => pgpRxMasters(0),
         sAxisSlave       => pgpRxSlaves(0),
         sAxisCtrl        => pgpRxCtrl(0),
         -- Streaming Master (Tx) Data Interface (mAxisClk domain)
         mAxisClk         => pgpTxClk,
         mAxisRst         => pgpTxRst,
         mAxisMaster      => pgpTxMasters(0),
         mAxisSlave       => pgpTxSlaves(0),
         -- AXI Lite Bus (axiLiteClk domain)
         axilClk          => pgpTxClk,
         axilRst          => pgpTxRst,
         mAxilWriteMaster => mAxilWriteMaster,
         mAxilWriteSlave  => mAxilWriteSlave,
         mAxilReadMaster  => mAxilReadMaster,
         mAxilReadSlave   => mAxilReadSlave);

--    SsiAxiLiteMaster_1 : entity surf.SsiAxiLiteMaster
--       generic map (
--          TPD_G               => TPD_G,
--          MEMORY_TYPE_G           => "block",
--          GEN_SYNC_FIFO_G     => false,
--          FIFO_ADDR_WIDTH_G   => 9,
--          FIFO_PAUSE_THRESH_G => 2**9-32,
--          AXI_STREAM_CONFIG_G => SSI_PGP2B_CONFIG_C)
--       port map (
--          sAxisClk            => pgpRxClk,
--          sAxisRst            => pgpRxRst,
--          sAxisMaster         => pgpRxMasters(0),
--          sAxisCtrl           => pgpRxCtrl(0),
--          mAxisClk            => pgpTxClk,
--          mAxisRst            => pgpTxRst,
--          mAxisMaster         => pgpTxMasters(0),
--          mAxisSlave          => pgpTxSlaves(0),
--          axiLiteClk          => pgpTxClk,
--          axiLiteRst          => pgpTxRst,
--          mAxiLiteWriteMaster => mAxilWriteMaster,
--          mAxiLiteWriteSlave  => mAxilWriteSlave,
--          mAxiLiteReadMaster  => mAxilReadMaster,
--          mAxiLiteReadSlave   => mAxilReadSlave);

   GEN_SEM_FIFOS : if (SEM_EN_G) generate

      -- VC1 SEM interface
      SEM_RX_FIFO : entity surf.AxiStreamFifoV2
         generic map (
            TPD_G               => TPD_G,
            PIPE_STAGES_G       => 1,
            SLAVE_READY_EN_G    => SIMULATION_G,
            SYNTH_MODE_G        => "xpm",
            MEMORY_TYPE_G       => "distributed",
            GEN_SYNC_FIFO_G     => false,
            FIFO_ADDR_WIDTH_G   => 5,
            FIFO_FIXED_THRESH_G => true,
            FIFO_PAUSE_THRESH_G => 2**5-2,
            SLAVE_AXI_CONFIG_G  => SSI_PGP2B_CONFIG_C,
            MASTER_AXI_CONFIG_G => SSI_PGP2B_CONFIG_C)
         port map (
            sAxisClk    => pgpRxClk,
            sAxisRst    => pgpRxRst,
            sAxisMaster => pgpRxMasters(1),
            sAxisSlave  => pgpRxSlaves(1),
            sAxisCtrl   => pgpRxCtrl(1),
            mAxisClk    => pgpTxClk,
            mAxisRst    => pgpTxRst,
            mAxisMaster => semRxAxisMaster,
            mAxisSlave  => semRxAxisSlave);

      SEM_TX_FIFO : entity surf.AxiStreamFifoV2
         generic map (
            TPD_G               => TPD_G,
            PIPE_STAGES_G       => 1,
            SLAVE_READY_EN_G    => true,
            SYNTH_MODE_G        => "xpm",
            MEMORY_TYPE_G       => "distributed",
            GEN_SYNC_FIFO_G     => true,
            FIFO_ADDR_WIDTH_G   => 5,
            FIFO_FIXED_THRESH_G => true,
            FIFO_PAUSE_THRESH_G => 2**5-2,
            SLAVE_AXI_CONFIG_G  => SSI_PGP2B_CONFIG_C,
            MASTER_AXI_CONFIG_G => SSI_PGP2B_CONFIG_C)
         port map (
            sAxisClk    => pgpTxClk,
            sAxisRst    => pgpTxRst,
            sAxisMaster => semTxAxisMaster,
            sAxisSlave  => semTxAxisSlave,
            mAxisClk    => pgpTxClk,
            mAxisRst    => pgpTxRst,
            mAxisMaster => pgpTxMasters(1),
            mAxisSlave  => pgpTxSlaves(1));
   end generate GEN_SEM_FIFOS;

   pgpRxCtrl(2)    <= AXI_STREAM_CTRL_UNUSED_C;
   pgpRxSlaves(2)  <= AXI_STREAM_SLAVE_FORCE_C;
   pgpTxMasters(2) <= AXI_STREAM_MASTER_INIT_C;


   LOOPBACK_FIFO : entity surf.AxiStreamFifoV2
      generic map (
         TPD_G               => TPD_G,
         PIPE_STAGES_G       => 1,
         SYNTH_MODE_G        => "xpm",
         MEMORY_TYPE_G       => "block",
         SLAVE_READY_EN_G    => false,
         GEN_SYNC_FIFO_G     => false,
         FIFO_ADDR_WIDTH_G   => 9,
         FIFO_FIXED_THRESH_G => true,
         FIFO_PAUSE_THRESH_G => 2**9-128,
         SLAVE_AXI_CONFIG_G  => SSI_PGP2B_CONFIG_C,
         MASTER_AXI_CONFIG_G => SSI_PGP2B_CONFIG_C)
      port map (
         sAxisClk    => pgpRxClk,
         sAxisRst    => pgpRxRst,
         sAxisMaster => pgpRxMasters(3),
         sAxisSlave  => open,
         sAxisCtrl   => pgpRxCtrl(3),
         mAxisClk    => pgpTxClk,
         mAxisRst    => pgpTxRst,
         mAxisMaster => pgpTxMasters(3),
         mAxisSlave  => pgpTxSlaves(3));



end rtl;

