/*
 * Copyright (c) 2026 Roberto Medina
 * SPDX-License-Identifier: Apache-2.0
 *
 * BioPulse Tile - a tiny vital-sign radar detector in silicon.
 *
 * From a single 8-bit radar/biosignal sample stream it:
 *   - tracks the signal baseline (slow EMA),
 *   - detects breathing cycles and classifies them
 *       (normal / fast / slow / irregular / apnea),
 *   - isolates and detects a faster "heartbeat" band,
 *   - estimates breaths-per-minute (sequential long division).
 *
 * One sample is processed per clock. uo_out shows the status flags, or the
 * 8-bit breaths-per-minute value when uio[2] (BPM readout select) is high.
 * Run the chip at a low clock for realistic vital-sign timescales, or feed
 * real samples at your sample rate.
 */

`default_nettype none

module tt_um_roberto_tiny_radar_tile (
    input  wire [7:0] ui_in,    // radar / biosignal 8-bit sample input
    output wire [7:0] uo_out,   // status flags / LEDs
    input  wire [7:0] uio_in,   // control inputs (lower 5 bits used)
    output wire [7:0] uio_out,  // UART + spectral debug (upper 3 bits)
    output wire [7:0] uio_oe,   // IO direction (1 = output)
    input  wire       ena,      // design enabled (always 1 when powered)
    input  wire       clk,      // clock
    input  wire       rst_n     // active-low reset
);

  // ------------------------------------------------------------------
  // Control inputs
  // ------------------------------------------------------------------
  wire       demo_mode = uio_in[0];
  wire       sens_sel  = uio_in[1];   // sensitivity: 0 = normal, 1 = low
  wire       bpm_sel   = uio_in[2];   // 1 = show breaths-per-minute on uo_out
  wire [1:0] demo_pat  = uio_in[4:3];

  assign uio_oe = 8'b1110_0000;     // uio[7:5] outputs, uio[4:0] inputs

  // ------------------------------------------------------------------
  // Parameters
  // ------------------------------------------------------------------

  // breathing classification thresholds, in sample ticks
  localparam [8:0] FAST_THR   = 9'd40;
  localparam [8:0] SLOW_THR   = 9'd110;
  localparam [8:0] APNEA_THR  = 9'd255;
  localparam [8:0] IRREG_MARG = 9'd24;
  localparam [4:0] WARMUP     = 5'd16;

  localparam [8:0]  HEART_TIMEOUT = 9'd40;    // heart "present" window (ticks)
  localparam [15:0] BPM_NUM       = 16'd1000; // BPM = BPM_NUM / period (ticks)
  localparam [7:0]  QUAL_THR      = 8'd24;    // peak-to-peak for "good" signal
  localparam [9:0]  FRAME_PERIOD  = 10'd512;  // clocks between UART frames


  // FSM states
  localparam [2:0] S_INIT   = 3'd0;
  localparam [2:0] S_NORMAL = 3'd1;
  localparam [2:0] S_FAST   = 3'd2;
  localparam [2:0] S_SLOW   = 3'd3;
  localparam [2:0] S_APNEA  = 3'd4;
  localparam [2:0] S_IRREG  = 3'd5;

  // ------------------------------------------------------------------
  // Sample-tick prescaler and phase counter
  // ------------------------------------------------------------------
  wire sample_tick = 1'b1;   // datapath advances every clock (no prescaler)

  // ------------------------------------------------------------------
  // Sensitivity -> breathing threshold margin
  // ------------------------------------------------------------------
  wire [7:0] thr = sens_sel ? 8'd32 : 8'd16;   // low / normal sensitivity

  // ------------------------------------------------------------------
  // Demo signal generator: breathing triangle + small heartbeat ripple
  // ------------------------------------------------------------------
  reg  [7:0] tri_val;     // 0..96
  reg        tri_dir;
  reg  [7:0] inc;
  always @(*) begin
    case (demo_pat)
      2'b00:   inc = 8'd3;   // normal -> period ~64
      2'b01:   inc = 8'd8;   // fast   -> period ~24
      2'b10:   inc = 8'd1;   // slow   -> period ~192
      default: inc = 8'd0;   // apnea  -> flat
    endcase
  end

  reg [2:0] hb_phase;       // heartbeat phase 0..7
  reg signed [3:0] hb;      // small ripple amplitude
  always @(posedge clk) begin
    if (!rst_n) begin
      tri_val  <= 8'd0;
      tri_dir  <= 1'b1;
      hb_phase <= 3'd0;
      hb       <= 4'sd0;
    end else if (sample_tick) begin
      // breathing triangle
      if (inc == 8'd0) begin
        tri_val <= 8'd48;                 // flat for apnea
      end else if (tri_dir) begin
        if (tri_val + inc >= 8'd96) begin tri_val <= 8'd96; tri_dir <= 1'b0; end
        else                              tri_val <= tri_val + inc;
      end else begin
        if (tri_val <= inc) begin tri_val <= 8'd0; tri_dir <= 1'b1; end
        else                      tri_val <= tri_val - inc;
      end
      // heartbeat ripple (period 8 ticks), suppressed in apnea
      hb_phase <= hb_phase + 3'd1;
      if (inc == 8'd0)            hb <= 4'sd0;
      else if (hb_phase < 3'd4)   hb <= 4'sd5;
      else                        hb <= -4'sd5;
    end
  end

  // 8-bit demo sample: 80 + triangle + heartbeat ripple (range ~75..181).
  // hb is sign-extended to 8 bits so the add stays 8-bit (no width warnings).
  wire [7:0] hb_ext      = {{4{hb[3]}}, hb};
  wire [7:0] demo_sample = (8'd80 + tri_val) + hb_ext;
  wire [7:0] sample = demo_mode ? demo_sample : ui_in;

  // ------------------------------------------------------------------
  // Slow baseline (EMA alpha 1/256) and medium EMA (alpha 1/16)
  // ------------------------------------------------------------------
  reg [15:0] base_acc;     // slow baseline,  alpha = 1/256
  reg [8:0]  med_acc;      // fast tracker,   alpha = 1/2 (heart high-pass)
  wire [7:0] baseline = base_acc[15:8];
  wire [7:0] med      = med_acc[8:1];

  always @(posedge clk) begin
    if (!rst_n) begin
      base_acc <= 16'h8000;     // 128.0
      med_acc  <= 9'h100;       // 128.0
    end else if (sample_tick) begin
      base_acc <= base_acc + {8'd0, sample} - {8'd0, baseline};
      med_acc  <= med_acc  + {1'd0, sample} - {1'd0, med};
    end
  end

  wire signed [9:0] heart_sig  = $signed({2'b00, sample}) - $signed({2'b00, med});

  // ------------------------------------------------------------------
  // Breathing threshold comparators and hysteresis cycle detector
  // ------------------------------------------------------------------
  wire [8:0] up_th = {1'b0, baseline} + {1'b0, thr};
  wire [8:0] lo_th = ({1'b0, baseline} >= {1'b0, thr})
                   ? ({1'b0, baseline} - {1'b0, thr}) : 9'd0;
  wire above = ({1'b0, sample} > up_th);
  wire below = ({1'b0, sample} < lo_th);

  // breath_evt is a 1-cycle pulse, valid AT the sample tick, so every
  // consumer (period counters, FSM, divider) sees it on the same edge.
  reg  hyst;
  wire breath_evt = sample_tick & above & ~hyst;
  always @(posedge clk) begin
    if (!rst_n) hyst <= 1'b0;
    else if (sample_tick) begin
      if (above && !hyst)      hyst <= 1'b1;
      else if (below && hyst)  hyst <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // Heartbeat band detector (hysteresis on heart_sig)
  // ------------------------------------------------------------------
  localparam signed [9:0] HTHR = 10'sd2;
  reg       hhyst;
  reg [8:0] heart_gap;          // ticks since last heart beat
  wire heart_evt = sample_tick & (heart_sig > HTHR) & ~hhyst;
  always @(posedge clk) begin
    if (!rst_n) begin
      hhyst <= 1'b0; heart_gap <= 9'd0;
    end else if (sample_tick) begin
      if (heart_sig > HTHR && !hhyst)      hhyst <= 1'b1;
      else if (heart_sig < -HTHR && hhyst) hhyst <= 1'b0;
      heart_gap <= heart_evt ? 9'd0
                 : (heart_gap != 9'h1FF ? heart_gap + 9'd1 : heart_gap);
    end
  end
  wire heart_detected = (heart_gap < HEART_TIMEOUT);

  // ------------------------------------------------------------------
  // Breathing period / apnea counters and classification FSM
  // ------------------------------------------------------------------
  reg [8:0] period_cnt, period, apnea_cnt;
  always @(posedge clk) begin
    if (!rst_n) begin
      period_cnt <= 9'd0; period <= 9'd0; apnea_cnt <= 9'd0;
    end else if (sample_tick) begin
      if (breath_evt) begin
        period <= period_cnt; period_cnt <= 9'd0; apnea_cnt <= 9'd0;
      end else begin
        if (period_cnt != 9'h1FF) period_cnt <= period_cnt + 9'd1;
        if (apnea_cnt  != 9'h1FF) apnea_cnt  <= apnea_cnt  + 9'd1;
      end
    end
  end

  wire [8:0] new_period = period_cnt;
  wire [8:0] pdiff = (new_period > period) ? (new_period - period)
                                           : (period - new_period);

  reg [2:0] state;
  reg [4:0] warm_cnt;
  wire warmed = (warm_cnt == WARMUP);
  always @(posedge clk) begin
    if (!rst_n) begin
      state <= S_INIT; warm_cnt <= 5'd0;
    end else if (sample_tick) begin
      if (!warmed) warm_cnt <= warm_cnt + 5'd1;
      if (apnea_cnt >= APNEA_THR) begin
        state <= S_APNEA;
      end else if (breath_evt) begin
        if (period != 9'd0 && pdiff > IRREG_MARG) state <= S_IRREG;
        else if (new_period < FAST_THR)           state <= S_FAST;
        else if (new_period > SLOW_THR)           state <= S_SLOW;
        else                                      state <= S_NORMAL;
      end
    end
  end

  // ------------------------------------------------------------------
  // Heart period counter -> heart-rate divider
  // ------------------------------------------------------------------
  reg [8:0] heart_cnt;
  always @(posedge clk) begin
    if (!rst_n) heart_cnt <= 9'd0;
    else if (sample_tick) begin
      if (heart_evt)                heart_cnt <= 9'd0;
      else if (heart_cnt != 9'h1FF) heart_cnt <= heart_cnt + 9'd1;
    end
  end

  // ------------------------------------------------------------------
  // Rate estimators (BPM = 1000 / period): breathing and heart
  // ------------------------------------------------------------------
  wire [7:0] breath_bpm, heart_bpm;
  div_const #(.NUM(BPM_NUM)) u_div_b (
      .clk(clk), .rst_n(rst_n), .start(breath_evt),
      .den(period_cnt), .quot(breath_bpm));
  div_const #(.NUM(BPM_NUM)) u_div_h (
      .clk(clk), .rst_n(rst_n), .start(heart_evt),
      .den(heart_cnt), .quot(heart_bpm));

  // ------------------------------------------------------------------
  // Signal-quality (peak-to-peak) + periodic UART frame timer
  // ------------------------------------------------------------------
  reg [7:0] s_max, s_min, pp_latch;
  reg [9:0] frame_cnt;
  reg       frame_tick;
  always @(posedge clk) begin
    if (!rst_n) begin
      s_max<=8'd0; s_min<=8'd255; pp_latch<=8'd0; frame_cnt<=10'd0; frame_tick<=1'b0;
    end else begin
      frame_tick <= 1'b0;
      if (sample_tick) begin
        if (sample > s_max) s_max <= sample;
        if (sample < s_min) s_min <= sample;
        if (frame_cnt == FRAME_PERIOD-1) begin
          pp_latch <= (s_max > s_min) ? (s_max - s_min) : 8'd0;
          s_max<=8'd0; s_min<=8'd255; frame_cnt<=10'd0; frame_tick<=1'b1;
        end else begin
          frame_cnt <= frame_cnt + 10'd1;
        end
      end
    end
  end
  wire quality_good = (pp_latch >= QUAL_THR);

  // ------------------------------------------------------------------
  // Outputs
  //   bpm_sel = 0 : uo_out shows the status flags
  //   bpm_sel = 1 : uo_out shows the 8-bit breaths-per-minute value
  // ------------------------------------------------------------------
  wire breathing = warmed && (state != S_INIT) && (state != S_APNEA);

  wire [7:0] flags = {warmed,            // [7] valid / status
                      quality_good,      // [6] signal quality good
                      heart_detected,    // [5] heartbeat detected
                      (state == S_IRREG),// [4] irregular
                      (state == S_SLOW), // [3] slow breathing
                      (state == S_FAST), // [2] fast breathing
                      (state == S_APNEA),// [1] apnea warning
                      breathing};        // [0] breathing detected

  assign uo_out = bpm_sel ? breath_bpm : flags;

  // ------------------------------------------------------------------
  // UART transmitter + frame sequencer (8N1, LSB first).
  //   frame: 0xAA, breath_bpm, heart_bpm, quality (pp), flags
  // ------------------------------------------------------------------
  reg  [7:0] tx_data;
  reg        tx_start;
  wire       tx_busy;
  wire       uart_tx_line;
  uart_tx #(.CLKS_PER_BIT(8)) u_uart (
      .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
      .tx(uart_tx_line), .busy(tx_busy));

  reg [2:0] fr_idx;
  reg       fr_active;
  reg [1:0] fr_wait;
  always @(posedge clk) begin
    if (!rst_n) begin
      fr_idx<=3'd0; fr_active<=1'b0; tx_start<=1'b0; tx_data<=8'd0; fr_wait<=2'd0;
    end else begin
      tx_start <= 1'b0;
      if (!fr_active) begin
        if (frame_tick) begin fr_active<=1'b1; fr_idx<=3'd0; fr_wait<=2'd0; end
      end else if (fr_wait != 2'd0) begin
        fr_wait <= fr_wait - 2'd1;
      end else if (!tx_busy) begin
        case (fr_idx)
          3'd0: tx_data <= 8'hAA;
          3'd1: tx_data <= breath_bpm;
          3'd2: tx_data <= heart_bpm;
          3'd3: tx_data <= pp_latch;
          default: tx_data <= flags;
        endcase
        tx_start <= 1'b1;
        fr_wait  <= 2'd2;
        if (fr_idx == 3'd4) fr_active <= 1'b0;
        else                fr_idx <= fr_idx + 3'd1;
      end
    end
  end

  // uio[5] = UART TX ; uio[7:6] = coarse breaths-per-minute (top bits)
  assign uio_out[4:0] = 5'd0;
  assign uio_out[5]   = uart_tx_line;
  assign uio_out[7:6] = breath_bpm[7:6];

  wire _unused = &{ena, uio_in[7:5], 1'b0};

endmodule


// ====================================================================
//  Sequential constant-numerator divider:  quot = NUM / den  (8-bit)
//  Restoring long division (shift the remainder, fixed-width compare -
//  no barrel shifter). One numerator bit per clock; saturates at 255.
// ====================================================================
module div_const #(parameter [15:0] NUM = 16'd1000) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,     // 1-cycle pulse to begin a new division
    input  wire [8:0] den,       // divisor
    output reg  [7:0] quot
);
  localparam [3:0] NB = 4'd10;   // numerator bit width (NUM <= 1023)
  reg [9:0] numsr;               // numerator, shifted out MSB-first
  reg [9:0] rem;                 // running remainder
  reg [9:0] q;                   // quotient accumulator
  reg [8:0] den_l;               // divisor, LATCHED at start (den may change)
  reg [3:0] cnt;
  reg       busy;

  wire [9:0] rem_sh = {rem[8:0], numsr[9]};   // bring down the next bit
  wire       ge     = (rem_sh >= {1'b0, den_l});
  wire [9:0] q_next = {q[8:0], ge};

  always @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0; quot <= 8'd0; numsr <= 10'd0; rem <= 10'd0; q <= 10'd0;
      den_l <= 9'd0; cnt <= 4'd0;
    end else if (start && (den != 9'd0)) begin
      numsr <= NUM[9:0]; rem <= 10'd0; q <= 10'd0; den_l <= den; cnt <= NB; busy <= 1'b1;
    end else if (busy) begin
      numsr <= {numsr[8:0], 1'b0};
      rem   <= ge ? (rem_sh - {1'b0, den_l}) : rem_sh;
      q     <= q_next;
      cnt   <= cnt - 4'd1;
      if (cnt == 4'd1) begin
        busy <= 1'b0;
        quot <= (q_next[9:8] != 2'd0) ? 8'd255 : q_next[7:0];   // saturate
      end
    end
  end

  // rem/q stay below their MSB in practice; tie off the unused top bits
  wire _unused_div = &{1'b0, rem[9], q[9]};
endmodule


// ====================================================================
//  Simple UART transmitter, 8N1, LSB first.
// ====================================================================
module uart_tx #(parameter [7:0] CLKS_PER_BIT = 8'd8) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
  reg [9:0] shifter;     // {stop=1, data[7:0], start=0}
  reg [3:0] nbits;
  reg [7:0] baud_cnt;

  always @(posedge clk) begin
    if (!rst_n) begin
      tx <= 1'b1; busy <= 1'b0; shifter <= 10'h3FF; nbits <= 4'd0; baud_cnt <= 8'd0;
    end else if (!busy) begin
      tx <= 1'b1;
      if (start) begin
        shifter  <= {1'b1, data, 1'b0};   // stop, data[7:0], start
        nbits    <= 4'd10;
        baud_cnt <= CLKS_PER_BIT - 1;
        busy     <= 1'b1;
      end
    end else begin
      if (baud_cnt != 8'd0) begin
        baud_cnt <= baud_cnt - 8'd1;
      end else begin
        baud_cnt <= CLKS_PER_BIT - 1;
        tx       <= shifter[0];
        shifter  <= {1'b1, shifter[9:1]};
        nbits    <= nbits - 4'd1;
        if (nbits == 4'd1) begin
          busy <= 1'b0;
          tx   <= 1'b1;
        end
      end
    end
  end
endmodule
