/* ****************************************************************************
-- (C) Copyright 2018 Kevin M. Hubbard - All rights reserved.
-- Source file: deep_sump.v
-- Date:        May  2018
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
--   0x18 : Read Deep-RAM Width+Length
--   0x19 : Read Deep-RAM Trigger Location + Status
--   0x1a : Read Deep-RAM Data ( address auto incrementing )
--   0x1b : Load Deep-RAM Read Pointer
--   0x1c : Load Deep-RAM Read Page
--   0x1d : Load Deep-Sump User Control ( handled by sump2.v )
--
-- Acquisition Interface:
--  clk_cap       _/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \__
--  events[31:0]  
--
-- Bus Interface:
--  clk_lb        _/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \__
--  ds_cmd_lb     -----<               >---<                   >------------
--  ds_wr_req     _________/   \____________________________________________
--  ds_wr_d[31:0] ---------<   >--------------------------------------------
--  ds_rd_req     _____________________________/   \______/    \____________
--  ds_rd_d[31:0] ---------------------------------<   >-------<   >--------
--  ds_rd_rdy     _________________________________/   \_______/   \________
--
-- Note: The ds_user_ctrl[31:0] bits may be used for user defined features
--       such as muxing in different event datasets or different instances
--       of deep_sump.v. For example, a single design might decide to have
--       both a fast Block RAM based deep_sump engine and also a slower DRAM.
--       The sump2.ini file has a variable deep_sump_user_ctrl that assigns.
-- Revision History:
-- Ver#  When      Who      What
-- ----  --------  -------- --------------------------------------------------
-- 0.1   05.01.18  khubbard Creation
-- ***************************************************************************/
`default_nettype none // Strictly enforce all nets to be declared


module deep_sump #
(
  parameter depth_len  =  65536,
  parameter depth_bits =  16
)
(
  input  wire                  reset,
  input  wire                  clk_cap,
  input  wire                  clk_lb,

  input  wire                  ds_trigger,
  input  wire [31:0]           ds_events,

  input  wire [5:0]            ds_cmd_cap, 
  input  wire [5:0]            ds_cmd_lb, 
  input  wire                  ds_rd_req,
  input  wire                  ds_wr_req,
  input  wire [31:0]           ds_wr_d, 
  output reg  [31:0]           ds_rd_d,
  output reg                   ds_rd_rdy,
  output reg                   ds_rle_pre_done, 
  output reg                   ds_rle_post_done, 
  output wire [31:0]           ds_user_cfg,

  output reg  [63:0]           a_di,
  output reg  [depth_bits-1:0] a_addr,
  output reg                   a_we,
  input  wire                  a_overrun,
  input  wire [63:0]           b_do,
  output reg  [depth_bits-1:0] b_addr,
  output reg                   b_rd_req 
);


  wire [31:0]             zeros;
  wire [31:0]             ones;
  wire [31:0]             ds_user_mask;
  reg  [5:0]              ctrl_cmd_lb;
  reg  [5:0]              ctrl_cmd_loc;
  wire [4:0]              ctrl_rd_page;
  reg                     rd_ptr_inc;
  reg                     rd_ptr_load;
  reg                     triggered_jk;
  reg  [depth_bits-1:0]   trigger_ptr;
  reg  [31:0]             ctrl_1b_reg;
  reg  [31:0]             ctrl_1c_reg;
  reg  [31:0]             ctrl_1e_reg;
  reg  [31:0]             ctrl_1f_reg;
  reg  [31:0]             ram_rd_d;
  reg  [31:0]             events_p1;
  reg  [31:0]             events_p2;
  reg  [31:0]             rle_time;
  reg  [31:0]             rle_time_p1;
  reg                     rle_wd_sample;
  reg  [7:0]              rle_wd_cnt;
  reg                     rle_wd_jk;
  reg                     rle_wd_long;
  reg                     rle_wd_short;
  reg                     rle_pre_jk;
  reg                     rle_done_jk;
  reg                     overrun_err_jk;


  assign zeros = 32'd0;
  assign ones  = 32'hFFFFFFFF;


//-----------------------------------------------------------------------------
// Input flops for timing.
//-----------------------------------------------------------------------------
always @ ( posedge clk_cap ) begin : proc_in   
  ctrl_cmd_loc <= ds_cmd_cap[5:0];
  events_p1    <= ds_events[31:0] & ~ ds_user_mask[31:0];
  events_p2    <= events_p1[31:0];
end // proc_in


//-----------------------------------------------------------------------------
// RLE Capture Logic. This captures and stores event changes along with 
// time stamps to a x64 RAM. 1st half of RAM is any pre-trigger activity.
// 2nd half of RAM is post-trigger activity. Pre-trig is circular and must
// be unrolled by software in correct order. 
//-----------------------------------------------------------------------------
always @ ( posedge clk_cap ) begin : proc_rle  
  a_we        <= 0;
  rle_time_p1 <= rle_time[31:0];
  // Prevent RLE from hanging in cases where no activity happens after the
  // trigger event by storing a non-changing sample periodically every
  // This value is a fine balance between limiting the max possible acquisition
  // time of no-activity and not wasting too many RLE samples storing idle
  // activity between bursty stuff.
  // Using rle_wd_long for a circuit that has gone truly idle would be bad as
  // it could take minutes to finish an acquisition. This circuit automatically
  // switches from long to short if long has been going on for a long time.
  // If there is activity, it will switch back from short to long.
  if ( rle_wd_jk == 0 ) begin 
    rle_wd_sample  <= rle_wd_long;
  end else begin
    rle_wd_sample  <= rle_wd_short;
  end

  // balance of max compression and waiting too long for pre/post to finish
  if (          depth_len >= 1048576 ) begin
    rle_wd_long  <= rle_time[ 9] & ~ rle_time_p1[ 9];
    rle_wd_short <= rle_time[ 8] & ~ rle_time_p1[ 8];
  end else if ( depth_len >= 65536 ) begin
    rle_wd_long  <= rle_time[11] & ~ rle_time_p1[11];
    rle_wd_short <= rle_time[ 8] & ~ rle_time_p1[ 8];
  end else if ( depth_len >= 16384 ) begin
    rle_wd_long  <= rle_time[13] & ~ rle_time_p1[13];
    rle_wd_short <= rle_time[ 8] & ~ rle_time_p1[ 8];
  end else begin
    rle_wd_long  <= rle_time[15] & ~ rle_time_p1[15];
    rle_wd_short <= rle_time[ 8] & ~ rle_time_p1[ 8];
  end


  // CMD_ARM   
  if ( ctrl_cmd_loc == 6'h01 ) begin
    if ( a_overrun == 1 ) begin
      overrun_err_jk <= 1;
    end
    rle_time <= rle_time[31:0] + 1;
    if ( triggered_jk == 0 ) begin
      a_addr[depth_bits-1] <= 0;// Pre-Trigger Half
      // If the prebuffer is invalid, store everything, change or no change
      // as to immediately fill up RAM with valid samples
      // Once prebuffer is valid, only store event deltas ( RLE )
// Note: Unlike regular SUMP, DeepSump can't store every sample pre-Trig as
//       this would overrun DRAM bandwidth. Instead pre-Trig buffer only
//       stores RLE events or rle_wd_sample. External RAM must be faster than
//       the rle_wd_short time.
//    if (   rle_pre_jk == 1 || rle_wd_sample == 1 ||
      if (                      rle_wd_sample == 1 ||
           ( events_p1 != events_p2[31:0] ) ) begin
        a_we <= 1;
        a_addr[depth_bits-2:0] <= a_addr[depth_bits-2:0] + 1; 

        // Adaptive RLE_WD
        if ( events_p1 == events_p2[31:0] ) begin
          if ( rle_wd_cnt == 8'hFF ) begin
            rle_wd_jk  <= 1;// Shorten the RLE_WD
          end else begin
            rle_wd_cnt <= rle_wd_cnt[7:0] + 1;// Allow up to 256 longs in a row
          end
        end else begin
          rle_wd_cnt <= 8'd0;// Restart the count since there was activity
          rle_wd_jk  <= 0;   // and switch back to rle_wd_long
        end

        if ( a_addr[depth_bits-2:0] == ones[depth_bits-2:0] ) begin
          rle_pre_jk <= 0;// PreBuffer is completely valid - and rolling
          rle_wd_jk  <= 0;
          rle_wd_cnt <= 8'd0;
        end
      end
    end else if ( triggered_jk == 1 && rle_done_jk == 0 ) begin
      if ( ( events_p1 != events_p2[31:0] ) || ( rle_wd_sample == 1) ) begin
        a_we <= 1;
        a_addr[depth_bits-2:0] <= a_addr[depth_bits-2:0] + 1; 

        // Adaptive RLE_WD
        if ( events_p1 == events_p2[31:0] ) begin
          if ( rle_wd_cnt == 8'hFF ) begin
            rle_wd_jk  <= 1;// Shorten the RLE_WD
          end else begin
            rle_wd_cnt <= rle_wd_cnt[7:0] + 1;
          end
        end else begin
          rle_wd_cnt <= 8'd0;
          rle_wd_jk  <= 0;// Long RLE_WD as there was activity
        end

        // If previous write was to last address in RAM, then call it quits
        if ( a_addr[depth_bits-2:0] == ones[depth_bits-2:0] ) begin
          rle_done_jk            <= 1;// Post-Trig RAM is full
          a_we                   <= 0;
          a_addr[depth_bits-2:0] <= a_addr[depth_bits-2:0];
        end
        // If previous cycle was pre-trig, set address to start of post trig
        if ( a_addr[depth_bits-1] == 0 ) begin
          a_addr[depth_bits-1]   <= 1;// Post-Trigger Half
          a_addr[depth_bits-2:0] <= zeros[depth_bits-2:0];
        end
      end
    end

    if ( rle_pre_jk == 0 && ds_trigger == 1 && triggered_jk == 0 ) begin
      triggered_jk <= 1;
      trigger_ptr  <= a_addr[depth_bits-1:0];
    end

  // CMD_RESET
  end else if ( ctrl_cmd_loc == 6'h02 ) begin
    overrun_err_jk <= 0;
    rle_time       <= 32'd0;// 43 seconds at 100 MHz
    a_addr         <= zeros[depth_bits-1:0];
    rle_pre_jk     <= 1;
    rle_done_jk    <= 0;
    rle_wd_jk      <= 0;
    rle_wd_cnt     <= 8'd0;
    triggered_jk   <= 0;
  end
  a_di[31:0]  <= events_p1[31:0];
  a_di[63:32] <= rle_time[31:0];
  ds_rle_pre_done  <= ~ rle_pre_jk;
  ds_rle_post_done <=   rle_done_jk;
end // proc_rle


//-----------------------------------------------------------------------------
// LocalBus readback of ctrl_reg and data_reg
//   0x18 : Read Deep-RAM Width+Length
//   0x19 : Read Deep-RAM Trigger Location + Status
//   0x1a : Read Deep-RAM Data ( address auto incrementing )
//   0x1b : Load Deep-RAM Read Pointer
//   0x1c : Load Deep-RAM Read Page
// Note: To be maximum latency tolerate for slow memories, this circuit is 
// always reading a pre-requested memory location and then advancing to next
// location after the read.
//-----------------------------------------------------------------------------
always @ ( posedge clk_lb ) begin : proc_lb_rd
  ctrl_cmd_lb <= ds_cmd_lb[5:0];
  ds_rd_d     <= 32'd0;
  ds_rd_rdy   <= 0;
  rd_ptr_inc  <= 0;
  rd_ptr_load <= 0;
  b_rd_req    <= 0;

  if ( ds_rd_req == 1 ) begin
    if ( ctrl_cmd_lb == 6'h19 ) begin
      ds_rd_d        <= trigger_ptr[depth_bits-1:0];// Note 2^28 limit
      ds_rd_d[31:28] <= { overrun_err_jk,rle_done_jk,triggered_jk,~rle_pre_jk};
      ds_rd_rdy      <= 1;
    end
    if ( ctrl_cmd_lb == 6'h1a ) begin
      ds_rd_d[31:0]  <= ram_rd_d[31:0]; 
      ds_rd_rdy      <= 1;
      rd_ptr_inc     <= 1;// Read data at current address and advance to next
    end
    if ( ctrl_cmd_lb == 6'h18 ) begin
      ds_rd_d[15:8]  <= 8'd2;      // Number of DWORDs (width rle_time+data)
      ds_rd_d[7:0]   <= depth_bits;// Number of Address Bits
      ds_rd_rdy      <= 1;
    end
  end 

  if ( ds_wr_req == 1 ) begin
    if ( ctrl_cmd_lb == 6'h1b ) begin
      ctrl_1b_reg <= ds_wr_d[31:0];
      rd_ptr_load <= 1;
    end
    if ( ctrl_cmd_lb == 6'h1c ) begin
      ctrl_1c_reg <= ds_wr_d[31:0];
    end
    if ( ctrl_cmd_lb == 6'h1e ) begin
      ctrl_1e_reg <= ds_wr_d[31:0];
    end
    if ( ctrl_cmd_lb == 6'h1f ) begin
      ctrl_1f_reg <= ds_wr_d[31:0];
    end
  end

  if ( rd_ptr_inc  == 1 ) begin 
    b_addr   <= b_addr[depth_bits-1:0] + 1;
    b_rd_req <= 1;
  end 
  if ( rd_ptr_load == 1 ) begin 
    b_addr   <= ctrl_1b_reg[depth_bits-1:0];
    b_rd_req <= 1;
  end 

  // Mux between the RLE timestamp and RLE event samples
  case( ctrl_rd_page[4:0] )
    5'H00   : ram_rd_d <= b_do[31:0];   // RLE Data 
    5'H01   : ram_rd_d <= b_do[63:32];  // RLE Time 
    default : ram_rd_d <= b_do[31:0];   // RLE Data 
  endcase

end // proc_lb_rd
  assign ctrl_rd_page = ctrl_1c_reg[4:0];
  assign ds_user_mask = ctrl_1e_reg[31:0];
  assign ds_user_cfg  = ctrl_1f_reg[31:0];


endmodule // deep_sump
