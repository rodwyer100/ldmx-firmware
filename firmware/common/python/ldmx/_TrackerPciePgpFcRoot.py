#!/usr/bin/env python3
##############################################################################
## This file is part of 'LDMX'.
## It is subject to the license terms in the LICENSE.txt file found in the
## top-level directory of this distribution and at:
##    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
## No part of 'LDMX', including this file,
## may be copied, modified, propagated, or distributed except according to
## the terms contained in the LICENSE.txt file.
##############################################################################

import rogue
import pyrogue as pr
import pyrogue.utilities.prbs
import pyrogue.interfaces.simulation

import axipcie

import ldmx

import argparse

#################################################################

class TrackerPciePgpFcRoot(pr.Root):
    def __init__(
            self,
            dev = '/dev/datadev_0',
            sim = False,
            prbsEn = False,
            numLanes = 1,
            numLinks = 4,
            numVc = 4,
            **kwargs):
        super().__init__(**kwargs)

#################################################################

        self.dmaStream = [[None for x in range(numVc)] for y in range(numLanes)]
        self.prbsRx    = [[None for x in range(numVc)] for y in range(numLanes)]
        self.prbsTx    = [[None for x in range(numVc)] for y in range(numLanes)]

        # Create PCIE memory mapped interface
        if sim:
            self.memMap = rogue.interfaces.memory.TcpClient('localhost', 11000)

            # Create the DMA loopback channel
            for lane in range(numLanes):
                for vc in range(numVc):
                    self.dmaStream[lane][vc] = rogue.interfaces.stream.TcpClient('localhost',8002+(512*lane)+2*vc)
        else:
#            self.memMap = pyrogue.interfaces.simulation.MemEmulate()
            self.memMap = rogue.hardware.axi.AxiMemMap(dev,)

            # Create the DMA loopback channel
            for lane in range(numLanes):
                for vc in range(numVc):
                    self.dmaStream[lane][vc] = rogue.hardware.axi.AxiStreamDma(dev,(0x100*lane)+vc,1)

        self.addInterface(self.memMap)

        if prbsEn:
            for lane in range(numLanes):
                for vc in range(numVc):
                    # Connect the SW PRBS Receiver module
                    self.prbsRx[lane][vc] = pr.utilities.prbs.PrbsRx(name=('SwPrbsRx[%d][%d]'%(lane,vc)),expand=True)
                    self.dmaStream[lane][vc] >> self.prbsRx[lane][vc]
                    self.add(self.prbsRx[lane][vc])

                    # Connect the SW PRBS Transmitter module
                    self.prbsTx[lane][vc] = pr.utilities.prbs.PrbsTx(name=('SwPrbsTx[%d][%d]'%(lane,vc)),expand=True)
                    self.prbsTx[lane][vc] >> self.dmaStream[lane][vc]
                    self.add(self.prbsTx[lane][vc])

        # Add the PCIe core device to base
        self.add(axipcie.AxiPcieCore(
            offset      = 0x00000000,
            memBase     = self.memMap,
            numDmaLanes = numLanes,
            expand      = True,
            sim         = sim,
        ))

        self.add(ldmx.PgpFc(
            offset   = 0x00800000,
            memBase  = self.memMap,
            numQuads = numLanes,
            numLinks = numLinks,
            numVc    = numVc,
            expand   = True))

class TrackerPciePgpFcArgParser(argparse.ArgumentParser):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # Add arguments
        self.add_argument(
            "--dev",
            type     = str,
            required = False,
            default  = '/dev/datadev_0',
            help     = "path to device driver",
        )

        self.add_argument(
            "--sim",
            action = 'store_true',
            default = False)

        self.add_argument(
            "--numLanes",
            "-l",
            type     = int,
            required = False,
            default  = 1,
            help     = "# of DMA Lanes (same as Transceiver Quads)",
        )

        self.add_argument(
            "--numLinks",
            "-lnk",
            type     = int,
            required = False,
            default  = 4,
            help     = "# of physical links (per quad)",
        )

        self.add_argument(
            "--numVc",
            "-vc",
            type     = int,
            required = False,
            default  = 4,
            help     = "# of virtual channels (per quad and per channel)",
        )

        self.add_argument(
            "--pollEn",
            action = 'store_true',
            default  = False,
            help     = "Enable auto-polling",
        )

        self.add_argument(
            "--prbsEn",
            action = 'store_true',
            default  = False,
            help     = "Connect software PRBS to DMA lanes",
        )

        self.add_argument(
            "--initRead",
            action = 'store_true',
            default  = False,
            help     = "Enable read all variables at start",
        )
