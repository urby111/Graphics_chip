`timescale 1ns / 1ps
// Stored 4x4 matrix * column vector (x,y,z,1).
// Matrix words, vertices and results are signed Q16.16.
// See docs/matrix_vertex.md for loading, stalls and numeric behavior.
module Matrix_Vertex (
    input  wire               clk,
    input  wire               rst,

    input  wire               matrix_valid,
    output wire               matrix_ready,
    input  wire signed [31:0] matrix_data,
    output reg                matrix_loaded,

    input  wire               vertex_valid,
    output wire               vertex_ready,
    input  wire signed [31:0] vertex_x,
    input  wire signed [31:0] vertex_y,
    input  wire signed [31:0] vertex_z,

    output wire               out_valid,
    input  wire               out_ready,
    output wire signed [31:0] result_x,
    output wire signed [31:0] result_y,
    output wire signed [31:0] result_z,
    output wire signed [31:0] result_w,
    output wire [3:0]         out_overflow // bits 0,1,2,3 = X,Y,Z,W
);
    reg signed [31:0] matrix [0:15];
    reg [3:0] load_index;
    reg [4:0] valid_pipe;
    wire advance = !valid_pipe[4] || out_ready;

    // Matrix requests have priority over new vertices. Drain all pending
    // results before modifying coefficients, including a stalled output.
    assign matrix_ready = !rst && (valid_pipe == 5'b0);
    assign vertex_ready = !rst && matrix_loaded && !matrix_valid && advance;
    assign out_valid = valid_pipe[4];

    always @(posedge clk) begin
        if (rst) begin
            load_index <= 4'd0;
            matrix_loaded <= 1'b0;
        end else if (matrix_valid && matrix_ready) begin
            matrix[load_index] <= matrix_data;
            load_index <= load_index + 4'd1;
            matrix_loaded <= (load_index == 4'd15);
        end
    end

    reg signed [31:0] x_reg, y_reg, z_reg;
    always @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 5'b0;
        end else if (advance) begin
            valid_pipe <= {valid_pipe[3:0], vertex_valid && vertex_ready};
            // Stage 0: capture the whole vertex on a single transfer.
            if (vertex_valid && vertex_ready) begin
                x_reg <= vertex_x;
                y_reg <= vertex_y;
                z_reg <= vertex_z;
            end
        end
    end

    // Arithmetic registers need no reset: valid_pipe controls ownership.
    // Input/product registers permit Vivado to use DSP pipeline registers.
    (* use_dsp = "yes" *) reg signed [63:0] product_x [0:3];
    (* use_dsp = "yes" *) reg signed [63:0] product_y [0:3];
    (* use_dsp = "yes" *) reg signed [63:0] product_z [0:3];
    reg signed [63:0] bias [0:3];
    reg signed [64:0] pair_xy [0:3];
    reg signed [64:0] pair_zb [0:3];
    reg signed [65:0] sum [0:3];
    reg [32:0] packed_result [0:3];

    // Products have 32 fractional bits. Drop 16 bits once, AFTER summation.
    // Discarding low bits rounds toward negative infinity (arithmetic shift).
    // Upper bits must all agree with the retained sign; otherwise saturate.
    /* verilator lint_off UNUSEDSIGNAL */
    function [32:0] pack_q16;
        input signed [65:0] value;
        begin
            if (value[65:47] != {19{value[65]}})
                pack_q16 = {1'b1, value[65] ? 32'h80000000 : 32'h7fffffff};
            else
                pack_q16 = {1'b0, value[47:16]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    genvar row;
    generate for (row = 0; row < 4; row = row + 1) begin : rows
        always @(posedge clk) begin
            if (!rst && advance) begin
                // Stage 1: 12 full-width products, four rows in parallel.
                product_x[row] <= x_reg * matrix[row*4];
                product_y[row] <= y_reg * matrix[row*4+1];
                product_z[row] <= z_reg * matrix[row*4+2];
                // Fourth input is exactly 1.0: align coefficient to Q32.32.
                bias[row] <= {{16{matrix[row*4+3][31]}},
                             matrix[row*4+3], 16'b0};
                // Stage 2: first level of a balanced, widened adder tree.
                pair_xy[row] <= {product_x[row][63], product_x[row]} +
                                {product_y[row][63], product_y[row]};
                pair_zb[row] <= {product_z[row][63], product_z[row]} +
                                {bias[row][63], bias[row]};
                // Stage 3: retain enough guard bits for the complete sum.
                sum[row] <= {pair_xy[row][64], pair_xy[row]} +
                            {pair_zb[row][64], pair_zb[row]};
                // Stage 4: narrow to the output format, reporting overflow.
                packed_result[row] <= pack_q16(sum[row]);
            end
        end
    end endgenerate

    assign result_x = packed_result[0][31:0];
    assign result_y = packed_result[1][31:0];
    assign result_z = packed_result[2][31:0];
    assign result_w = packed_result[3][31:0];
    assign out_overflow = {packed_result[3][32], packed_result[2][32],
                           packed_result[1][32], packed_result[0][32]};
endmodule
