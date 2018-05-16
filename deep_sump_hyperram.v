/* ****************************************************************************
-- (C) Copyright 2018 Kevin M. Hubbard - All rights reserved.
-- Source file: deep_sump_hyperram.v
-- Date:        July 2018
-- Author:      khubbard
-- Description: Deep Sump extension to sump2.v logic analyzer. This uses a FIFO
--              and a slow deep memory ( either internal or external ) for 
--              extending event capture window in a parallel storage path.
-- Language:    Verilog-2001
-- Simulation:  Mentor-Modelsim
-- Synthesis:   Xilint-XST,Xilinx-Vivado,Lattice-Synplify
-- License:     This project is licensed with the CERN Open Hardware Licence
--              v1.2.  You may redistribute and modify this project under the
--              terms of the CERN OHL v.1.2. (http://ohwr.org/cernohl).
--              This project is distributed WITHOUT ANY EXPRESS OR IMPLIED
--              WARRANTY, INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY
--              AND FITNESS FOR A PARTICULAR PURPOSE. Please see the CERN OHL
--              v.1.2 for applicable Conditions.
--
-- Revision History:
-- Ver#  When      Who      What
-- ----  --------  -------- --------------------------------------------------
-- 0.1   04.29.18  khubbard Creation
-- ***************************************************************************/
`default_nettype none // Strictly enforce all nets to be declared

// Note: The RAM depth len+bits is for 64bits.
// Take total number of bits and divide by 64 to get depth_len

module deep_sump_hyperram #
(
  parameter depth_len  = 65536,
  parameter depth_bits = 16
)
(
  input  wire                  reset,   
  input  wire                  a_clk,   
  input  wire                  b_clk,   

  input  wire                  a_we,
  input  wire [depth_bits-1:0] a_addr,
  input  wire [63:0]           a_di,
  output reg                   a_overrun,

  input  wire                  b_rd_req,
  input  wire [depth_bits-1:0] b_addr,
  output reg  [63:0]           b_do,

  input  wire [7:0]            dram_dq_in,
  output wire [7:0]            dram_dq_out,
  output wire                  dram_dq_oe_l,

  input  wire                  dram_rwds_in,
  output wire                  dram_rwds_out,
  output wire                  dram_rwds_oe_l,

  output wire                  dram_ck,
  output wire                  dram_rst_l,
  output wire                  dram_cs_l,
  output wire [7:0]            sump_dbg 
);


  reg  [107:0]            fifo_din;
  reg                     fifo_wr_en;
  reg                     fifo_rd_en;
  wire [107:0]            fifo_dout;
  reg  [107:0]            fifo_dout_q;
  wire                    fifo_full;
  wire                    fifo_almost_full;
  wire                    fifo_overflow;
  wire                    fifo_empty;
  wire                    fifo_almost_empty;
  wire                    fifo_valid;
  reg                     fifo_valid_p1;
  reg                     fifo_valid_p2;

  reg                     hr_rd_req;
  reg                     hr_wr_req;
  reg                     hr_mem_or_reg;
  reg  [3:0]              hr_wr_byte_en;
  reg  [31:0]             hr_addr;
  reg  [5:0]              hr_rd_num_dwords;
  reg  [31:0]             hr_wr_d;
  wire [31:0]             hr_rd_d;
  reg  [63:0]             hr_rd_d_sr;
  wire                    hr_rd_rdy;
  wire                    hr_busy;
  wire                    hr_burst_wr_rdy;
  reg  [7:0]              hr_latency_1x;
  reg  [7:0]              hr_latency_2x;
  reg  [7:0]              hr_wr_sr;
  reg                     cfg_done_jk;
  reg                     dword_two_jk;
  reg  [15:0]             fifo_rd_en_sr;
  wire                    lat_2x;


//-----------------------------------------------------------------------------
// Deep Sump pushes write address+data to a FIFO. 
//-----------------------------------------------------------------------------
always @( posedge a_clk )
begin
  fifo_din       <= 108'd0;
  fifo_din[depth_bits-1+64:64] <= a_addr[depth_bits-1:0];
  fifo_din[63:0] <= a_di[63:0];
  fifo_wr_en     <= a_we;
  a_overrun      <= fifo_full | fifo_almost_full;// mark capture as invalid

  if ( fifo_almost_full == 1 || fifo_full == 1 ) begin
    fifo_wr_en <= 0;
  end
end // always


//-----------------------------------------------------------------------------
// Instead of waiting 150uS from Power On to configure the HyperRAM, wait 
// until the 1st time FIFO goes not-empty from Reset and then issue the cfg.
//   Default 6 Clock 166 MHz Latency, latency1x=0x12, latency2x=0x16
//     CfgReg0 write(0x00000800, 0x8f1f0000);
//   Configd 3 Clock  83 MHz Latency, latency1x=0x04, latency2x=0x0a
//     CfgReg0 write(0x00000800, 0x8fe40000);
//
// The FIFO with Deep Sump writes gets popped whenever HyperRAM is available. 
// Deep Sump read requests are multi cycle. They come in on the b_clk domain
//-----------------------------------------------------------------------------
always @( posedge b_clk )
begin
  hr_wr_sr         <= { hr_wr_sr[6:0], hr_wr_req };
  hr_latency_1x    <= 8'h04;
  hr_latency_2x    <= 8'h0a;
  hr_rd_num_dwords <= 6'd2;
  hr_wr_byte_en    <= 4'hF;
  hr_rd_req        <= 0;
  hr_wr_req        <= 0;
  hr_mem_or_reg    <= 0;
  fifo_rd_en       <= 0;
  fifo_rd_en_sr    <= { fifo_rd_en_sr[14:0], fifo_rd_en };
  fifo_valid_p1    <= fifo_valid;
  fifo_valid_p2    <= fifo_valid_p1;
  b_do             <= hr_rd_d_sr[63:0];


  if ( hr_busy == 0 && hr_wr_sr == 8'd0 ) begin 
    if ( cfg_done_jk == 1 && b_rd_req == 1 ) begin
      hr_addr                   <= 32'd0;
      hr_addr[depth_bits-1+1:0] <= {b_addr[depth_bits-1:0],1'b0};// Note 64->32
      hr_rd_req                 <= 1;
    end
  end 

  if ( hr_rd_rdy == 1 ) begin 
    hr_rd_d_sr <= { hr_rd_d_sr[31:0], hr_rd_d[31:0] };
  end

  // Configure HyperRAM optimal latency on 1st FIFO push after powerup
  if ( cfg_done_jk == 0 && fifo_empty == 0 ) begin
    cfg_done_jk   <= 1;
    hr_addr       <= 32'h00000800;
    hr_wr_d       <= 32'h8fe40000;
    hr_mem_or_reg <= 1;// Config Reg Write instead of DRAM Write
    hr_wr_req     <= 1;
  end

  // When FIFO has data, pop 32bits of Address and 64bits of Data and then
  // Push those 2 DWORDs of Data to HyperRAM as a burst.
  if ( hr_busy == 0 && hr_wr_sr == 8'd0 && 
       fifo_rd_en_sr == 16'd0 && fifo_rd_en == 0 ) begin 
    if ( cfg_done_jk == 1 && fifo_empty == 0 ) begin
      fifo_rd_en <= 1;// Pop Addr+Data off of FIFO for a HyperRAM Write
    end 
  end

  if ( fifo_valid == 1 && fifo_valid_p1 == 0 ) begin 
    fifo_dout_q  <= fifo_dout[107:0];
  end

  // 1st DWORD is sent to DRAM as soon as FIFO pops it
  if ( fifo_valid_p1 == 1 && fifo_valid_p2 == 0 ) begin 
    hr_addr      <= { fifo_dout_q[94:64], 1'b0 };// Burst Address. Note 64->32
    hr_wr_d      <= fifo_dout_q[63:32];// Burst Data DWORD-1
    dword_two_jk <= 1;// Queue up for the 2nd DWORD
    hr_wr_req    <= 1;
  end 

  // 2nd DWORD is the burst. It just waits for hr_burst_wr_rdy
  if ( dword_two_jk == 1 && hr_burst_wr_rdy == 1 ) begin 
    hr_addr      <= { fifo_dout_q[94:64],1'b0};// Don't Care, just saves gates
    hr_wr_d      <= fifo_dout_q[31:0]; // Burst Data DWORD-2
    dword_two_jk <= 0;
    hr_wr_req    <= 1;
  end 


  if ( reset == 1 ) begin 
    cfg_done_jk  <= 0;
    dword_two_jk <= 0;
  end 
end // always


//-----------------------------------------------------------------------------
// Rate converting FIFO for HyperRAM DRAM access.
//
// Push Side
//   wr_clk _/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_
//   wr_en  _____/   \___
//   din    -----<   >---
//   almost_full
//   overflow
//
// Pop Side
//   rd_clk _/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_
//   rd_en  _____________________/   \__________
//   valid  _____________________________/   \__
//   dout   -----------------------------<   >--
//   empty
//   almost_empty
//-----------------------------------------------------------------------------
fifo_xilinx_512x108 u_fifo_xilinx_512x108
(
  .rst               ( reset                 ),
  .wr_clk            ( a_clk                 ),
  .rd_clk            ( b_clk                 ),
  .din               ( fifo_din[107:0]       ),
  .wr_en             ( fifo_wr_en            ),
  .rd_en             ( fifo_rd_en            ),
  .dout              ( fifo_dout[107:0]      ),
  .full              ( fifo_full             ),
  .almost_full       ( fifo_almost_full      ),
  .overflow          ( fifo_overflow         ),
  .empty             ( fifo_empty            ),
  .almost_empty      ( fifo_almost_empty     ),
  .valid             ( fifo_valid            )
);

  assign sump_dbg[0] = fifo_wr_en;
  assign sump_dbg[1] = fifo_rd_en;
//assign sump_dbg[2] = fifo_full;
//assign sump_dbg[2] = fifo_almost_full;
  assign sump_dbg[2] = dram_rwds_in;
  assign sump_dbg[3] = lat_2x;

  assign sump_dbg[4] = hr_wr_req;
  assign sump_dbg[5] = hr_rd_req;
  assign sump_dbg[6] = hr_busy;  
  assign sump_dbg[7] = ~dram_cs_l;


//-----------------------------------------------------------------------------
// Bridge to a HyperRAM
//-----------------------------------------------------------------------------
hyper_xface u_hyper_xface
(
  .reset             ( reset                 ),
  .clk               ( b_clk                 ),
  .rd_req            ( hr_rd_req             ),
  .wr_req            ( hr_wr_req             ),
  .mem_or_reg        ( hr_mem_or_reg         ),
  .wr_byte_en        ( hr_wr_byte_en         ),
  .addr              ( hr_addr[31:0]         ),
  .rd_num_dwords     ( hr_rd_num_dwords[5:0] ),
  .wr_d              ( hr_wr_d[31:0]         ),
  .rd_d              ( hr_rd_d[31:0]         ),
  .rd_rdy            ( hr_rd_rdy             ),
  .busy              ( hr_busy               ),
  .lat_2x            ( lat_2x                ),
  .burst_wr_rdy      ( hr_burst_wr_rdy       ),
  .latency_1x        ( hr_latency_1x[7:0]    ),
  .latency_2x        ( hr_latency_2x[7:0]    ),
  .dram_dq_in        ( dram_dq_in[7:0]       ),
  .dram_dq_out       ( dram_dq_out[7:0]      ),
  .dram_dq_oe_l      ( dram_dq_oe_l          ),
  .dram_rwds_in      ( dram_rwds_in          ),
  .dram_rwds_out     ( dram_rwds_out         ),
  .dram_rwds_oe_l    ( dram_rwds_oe_l        ),
  .dram_ck           ( dram_ck               ),
  .dram_rst_l        ( dram_rst_l            ),
  .dram_cs_l         ( dram_cs_l             ),
  .sump_dbg          (                       )
);// module hyper_xface


endmodule // deep_sump_hyperram
