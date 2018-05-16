/* ****************************************************************************
-- (C) Copyright 2018 Kevin M. Hubbard - All rights reserved.
-- Source file: deep_sump_ram.v
-- Date:        May  2018
-- Author:      khubbard
-- Description: Deep Sump extension to sump2.v logic analyzer. This is a 
--              simple inferrable Block RAM.
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
-- a_clk      _/ \_/ \_/ \_/ \_/ \_/ \_/ \_
-- a_we       _____/  \____/      \_______
-- a_addr     -----<  >----<  ><  >-------
-- a_di       -----<  >----<  ><  >-------
-- 
-- b_clk      _/ \_/ \_/ \_/ \_/ \_/ \_/ \_
-- b_rd_req   _____/   \_______/   \_______
-- b_addr     -----<          ><           >
-- b_do       ----------<     >--------<   >
--
-- Revision History:
-- Ver#  When      Who      What
-- ----  --------  -------- --------------------------------------------------
-- 0.1   05.01.18  khubbard Creation
-- ***************************************************************************/
`default_nettype none // Strictly enforce all nets to be declared


module deep_sump_ram #
(
  parameter depth_len  = 65536,
  parameter depth_bits = 16
)
(
  input  wire                  a_clk,   
  input  wire                  b_clk,   

  input  wire                  a_we,
  input  wire [depth_bits-1:0] a_addr,
  input  wire [63:0]           a_di,
  output wire                  a_overrun,

  input  wire                  b_rd_req,
  input  wire [depth_bits-1:0] b_addr,
  output wire [63:0]           b_do
);

// Variable Size Capture BRAM
  reg  [63:0]             rle_ram_array[depth_len-1:0];
  reg  [depth_bits-1:0]   a_addr_p1;
  reg  [depth_bits-1:0]   a_addr_p2;
  reg                     a_we_p1;
  reg                     a_we_p2;
  reg  [63:0]             a_di_p1;
  reg  [63:0]             a_di_p2;
  reg  [depth_bits-1:0]   b_addr_p1;
  reg  [63:0]             b_do_loc;
  reg  [63:0]             b_do_p1;

  assign a_overrun = 0;// This would assert if RAM wasn't available for write


//-----------------------------------------------------------------------------
// Data Dual Port RAM - Infer RAM here to make easy to change depth on the fly
//-----------------------------------------------------------------------------
always @( posedge a_clk )
begin
  a_we_p1   <= a_we;
  a_we_p2   <= a_we_p1;
  a_addr_p1 <= a_addr;
  a_addr_p2 <= a_addr_p1;
  a_di_p1   <= a_di;
  a_di_p2   <= a_di_p1;
  if ( a_we_p2 ) begin
    rle_ram_array[a_addr_p2] <= a_di_p2;
  end // if ( a_we )
end // always


//-----------------------------------------------------------------------------
// 2nd Port of RAM is clocked from local bus
//-----------------------------------------------------------------------------
always @( posedge b_clk )
begin
  b_addr_p1 <= b_addr;
  b_do_loc  <= rle_ram_array[b_addr_p1] ;
  b_do_p1   <= b_do_loc;
end // always
  assign b_do = b_do_p1[63:0];


endmodule // deep_sump_ram
