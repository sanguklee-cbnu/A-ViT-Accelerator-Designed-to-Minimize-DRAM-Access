`timescale 1ns/1ps
`default_nettype none

// 32x32 PE array (INT8 GEMM tile)
// - in_valid ????: C[r,c] += A_row[r] * B_col[c]
// - first = ??? ????? ? MAC ??????????? 1
// - tile_last = ??? ????? ?????? MAC ????????? 1
// - PE?? tile_last ??????? ???? ????? out_data?? ????,
//   ???? ????????? out_valid=1 ?? ????? drain ????
// - ????? col-major drain (WRITEBACK/GOUT col-packed ????):
//   out_col_idx = col index (0..31)
//   out_col_data_flat = [row0..31] (32 lanes)
module pe_array #(
  parameter integer OUTW = 32
)(
  input  wire                   clk,
  input  wire                   nRst,

  input  wire                   in_valid,
  input  wire                   first,
  input  wire                   tile_last,


  input  wire                   a_is_qlog,
  input  wire [32*8-1:0]        a_rows_flat,    // [row*8 +: 8]
  input  wire [32*8-1:0]        b_cols_flat,    // [col*8 +: 8]

  output reg                    out_col_valid,      // ???? ??? (col vector)
  input  wire                   out_col_ready,      // ????? ready
  output reg  [4:0]             out_col_idx,        // col index (0..31)
  output reg  [32*OUTW-1:0]     out_col_data_flat,  // col vector data (row0..31)

  output reg                    busy,
  output reg                    done
);

  localparam integer M   = 32;
  localparam integer N   = 32;
  localparam integer NUM = 1024;

  wire [NUM-1:0]          pe_v;
  wire [NUM*OUTW-1:0]     pe_d_flat;

  // tile_last 1-cycle delay:
  reg tile_last_d1;
  always @(posedge clk or negedge nRst) begin
    if (!nRst) tile_last_d1 <= 1'b0;
    else       tile_last_d1 <= tile_last;
  end

  // --------------------------
  // drain state (COL-major)
  // --------------------------
  reg        streaming;
  reg [4:0]  cur_col;     // 0..31: ???? col index

  wire fire     = streaming && out_col_valid && out_col_ready;
  wire last_vec = (cur_col == 5'd31);

  wire start_drain = (!streaming) && tile_last_d1;

  // pop one-hot: ???? cur_col ????? ???? ???? 1
  reg [31:0] pop_oh_col;
  integer t;
  always @* begin
    pop_oh_col = 0;
    if (fire) pop_oh_col[cur_col] = 1'b1;
  end

  // --------------------------
  // PE instances
  // - col-major drain????,
  //   ???? col?? PE?? pop(out_ready) ????
  // --------------------------
  genvar r, c;
  generate
    for (r = 0; r < M; r = r + 1) begin : GEN_ROW
      for (c = 0; c < N; c = c + 1) begin : GEN_COL
        localparam integer IDX = r*N + c;

        wire pe_out_ready = pop_oh_col[c];

        pe_int8_mac #(.OUTW(OUTW)) u_pe (
          .clk       (clk),
          .rstn      (nRst),
          .in_valid  (in_valid),
          .first     (first),
          .tile_last (tile_last),
          .a_is_qlog(a_is_qlog),
          .a         (a_rows_flat[r*8 +: 8]),
          .b         (b_cols_flat[c*8 +: 8]),
          .out_valid (pe_v[IDX]),
          .out_ready (pe_out_ready),
          .out_data  (pe_d_flat[IDX*OUTW +: OUTW])
        );
      end
    end
  endgenerate

  // --------------------------
  // packer index (???? col ??????? ????)
  // - drain ???? ?????? col=0
  // - drain ????? fire && !last?? ???? col?? ??? ???
  // --------------------------
  wire [4:0] col_for_packer =
    (!streaming)        ? 5'd0 :
    (fire && !last_vec) ? (cur_col + 5'd1) :
                           cur_col;

  // --------------------------
  // col-major ???? ??ии
  //   col_for_packer?? 32?? row?? [0..31] ?????? pack
  // --------------------------
  reg [32*OUTW-1:0] vec_data_sel;
  reg               vec_valid_sel;

  integer i;
  always @* begin
    vec_data_sel  = 0;
    vec_valid_sel = 1'b1;

    // col vector: rows 0..31
    for (i = 0; i < 32; i = i + 1) begin
      // PE index = (row=i, col=col_for_packer) => IDX = i*32 + col
      vec_valid_sel = vec_valid_sel & pe_v[(i*32) + col_for_packer];
      vec_data_sel[i*OUTW +: OUTW] =
        pe_d_flat[((i*32 + col_for_packer)*OUTW) +: OUTW];
    end
  end

  // --------------------------
  // output registers
  // --------------------------
  always @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      streaming         <= 1'b0;
      cur_col           <= 5'd0;

      out_col_valid     <= 1'b0;
      out_col_idx       <= 5'd0;
      out_col_data_flat <= 0;

      busy              <= 1'b0;
      done              <= 1'b0;
    end else begin
      done <= 1'b0;

      if (!streaming) begin
        busy          <= 1'b0;
        out_col_valid <= 1'b0;
        out_col_idx   <= 5'd0;

        if (start_drain) begin
          streaming         <= 1'b1;
          busy              <= 1'b1;
          cur_col           <= 5'd0;

          out_col_idx       <= 5'd0;
          out_col_data_flat <= vec_data_sel;   // col_for_packer=0
          out_col_valid     <= vec_valid_sel;
        end

      end else begin
        busy <= 1'b1;

        if (fire) begin
          if (last_vec) begin
            streaming     <= 1'b0;
            busy          <= 1'b0;
            out_col_valid <= 1'b0;
            done          <= 1'b1;
          end else begin
            cur_col           <= cur_col + 5'd1;
            out_col_idx       <= cur_col + 5'd1;
            out_col_data_flat <= vec_data_sel;  // col_for_packer = cur_col+1
            out_col_valid     <= vec_valid_sel;
          end
        end
        // fire=0??? ???? payload ????
      end
    end
  end

endmodule

`default_nettype wire
