`timescale 1ns / 1ps
// Matrix_Vertex outputs -> integer screen coordinates. Focal length is already
// in the matrix. X/Y/Z/W and near_q16 are signed Q16.16; dimensions are pixels.
// x2d=floor(width/2 + X/W), y2d=floor(height/2 - Y/W).
// Two pipelined restoring dividers; no combinational '/' operator.
module Screen_Position (
    input wire clk, rst,
    input wire in_valid,
    output wire in_ready,
    input wire signed [31:0] in_x, in_y, in_z, in_w,
    input wire [3:0] in_overflow,
    input wire [15:0] screen_width, screen_height,
    input wire signed [31:0] near_q16,
    input wire buffer_select,

    output wire out_valid,
    input wire out_ready,
    output reg signed [31:0] x2d, y2d,
    output reg signed [31:0] out_depth,
    output reg out_in_frame, out_rejected,
    output reg out_buffer_select,
    output reg [15:0] out_width, out_height,
    output wire busy
);
    localparam DIV_BITS = 33;
    reg [36:0] valid_pipe;
    wire advance = !valid_pipe[36] || out_ready;
    assign in_ready = !rst && advance;
    assign out_valid = valid_pipe[36];
    assign busy = |valid_pipe;

    reg [32:0] numerator_x [0:DIV_BITS], numerator_y [0:DIV_BITS];
    reg [32:0] quotient_x [0:DIV_BITS], quotient_y [0:DIV_BITS];
    reg [31:0] remainder_x [0:DIV_BITS], remainder_y [0:DIV_BITS];
    reg [31:0] divisor [0:DIV_BITS];
    reg negative_x [0:DIV_BITS], negative_y [0:DIV_BITS];
    reg rejected [0:35], selected [0:35];
    reg [15:0] width_pipe [0:35], height_pipe [0:35];
    reg signed [31:0] depth_pipe [0:35];
    wire [31:0] magnitude_x = in_x[31] ? (~in_x + 32'd1) : in_x;
    wire [31:0] magnitude_y = in_y[31] ? (~in_y + 32'd1) : in_y;

    always @(posedge clk) begin
        if (rst) valid_pipe <= 37'b0;
        else if (advance) begin
            valid_pipe <= {valid_pipe[35:0], in_valid && in_ready};
            // Divide 2*abs(coordinate)/W. Keeping half-pixel units until the
            // centre addition handles odd screen sizes and negative fractions.
            numerator_x[0] <= {magnitude_x, 1'b0};
            numerator_y[0] <= {magnitude_y, 1'b0};
            quotient_x[0] <= 33'b0;
            quotient_y[0] <= 33'b0;
            remainder_x[0] <= 32'b0;
            remainder_y[0] <= 32'b0;
            divisor[0] <= (in_w > 0) ? in_w : 32'd1;
            negative_x[0] <= in_x[31];
            negative_y[0] <= !in_y[31]; // screen Y runs downward
            rejected[0] <= (|in_overflow) || (in_w <= 0) ||
                           (near_q16 <= 0) || (in_z < near_q16) ||
                           (screen_width == 0) || (screen_height == 0);
            selected[0] <= buffer_select;
            width_pipe[0] <= screen_width;
            height_pipe[0] <= screen_height;
            depth_pipe[0] <= in_z;
        end
    end

    genvar stage;
    generate for (stage = 0; stage < DIV_BITS; stage = stage + 1) begin : divide
        wire [32:0] trial_x = {remainder_x[stage], numerator_x[stage][32]};
        wire [32:0] trial_y = {remainder_y[stage], numerator_y[stage][32]};
        wire [32:0] diff_x = trial_x - {1'b0, divisor[stage]};
        wire [32:0] diff_y = trial_y - {1'b0, divisor[stage]};
        always @(posedge clk) begin
            if (!rst && advance) begin
                numerator_x[stage+1] <= {numerator_x[stage][31:0], 1'b0};
                numerator_y[stage+1] <= {numerator_y[stage][31:0], 1'b0};
                remainder_x[stage+1] <= diff_x[32] ? trial_x[31:0] : diff_x[31:0];
                remainder_y[stage+1] <= diff_y[32] ? trial_y[31:0] : diff_y[31:0];
                quotient_x[stage+1] <= {quotient_x[stage][31:0], !diff_x[32]};
                quotient_y[stage+1] <= {quotient_y[stage][31:0], !diff_y[32]};
                divisor[stage+1] <= divisor[stage];
                negative_x[stage+1] <= negative_x[stage];
                negative_y[stage+1] <= negative_y[stage];
                rejected[stage+1] <= rejected[stage];
                selected[stage+1] <= selected[stage];
                width_pipe[stage+1] <= width_pipe[stage];
                height_pipe[stage+1] <= height_pipe[stage];
                depth_pipe[stage+1] <= depth_pipe[stage];
            end
        end
    end endgenerate

    reg signed [33:0] offset_x, offset_y, pixel_x, pixel_y;
    wire coordinate_overflow = (pixel_x[33:31] != {3{pixel_x[33]}}) ||
                               (pixel_y[33:31] != {3{pixel_y[33]}});
    always @(posedge clk) begin
        if (!rst && advance) begin
            // Stage 34: floor(2*X/W), floor(-2*Y/W), including signed minima.
            offset_x <= negative_x[33] ?
                -$signed({1'b0, quotient_x[33]}) -
                    ((remainder_x[33] != 0) ? 34'sd1 : 34'sd0) :
                $signed({1'b0, quotient_x[33]});
            offset_y <= negative_y[33] ?
                -$signed({1'b0, quotient_y[33]}) -
                    ((remainder_y[33] != 0) ? 34'sd1 : 34'sd0) :
                $signed({1'b0, quotient_y[33]});
            rejected[34] <= rejected[33]; selected[34] <= selected[33];
            width_pipe[34] <= width_pipe[33]; height_pipe[34] <= height_pipe[33];
            depth_pipe[34] <= depth_pipe[33];
            // Stage 35: centre and convert half-pixel units to whole pixels.
            pixel_x <= (offset_x + $signed({18'b0, width_pipe[34]})) >>> 1;
            pixel_y <= (offset_y + $signed({18'b0, height_pipe[34]})) >>> 1;
            rejected[35] <= rejected[34]; selected[35] <= selected[34];
            width_pipe[35] <= width_pipe[34]; height_pipe[35] <= height_pipe[34];
            depth_pipe[35] <= depth_pipe[34];
            // Stage 36: output and point bounds check. Never wrap coordinates.
            x2d <= (rejected[35] || coordinate_overflow) ? 32'sd0 : pixel_x[31:0];
            y2d <= (rejected[35] || coordinate_overflow) ? 32'sd0 : pixel_y[31:0];
            out_rejected <= rejected[35] || coordinate_overflow;
            out_in_frame <= !rejected[35] && !coordinate_overflow &&
                (pixel_x >= 0) && (pixel_y >= 0) &&
                (pixel_x < $signed({18'b0, width_pipe[35]})) &&
                (pixel_y < $signed({18'b0, height_pipe[35]}));
            out_depth <= depth_pipe[35];
            out_width <= width_pipe[35]; out_height <= height_pipe[35];
            out_buffer_select <= selected[35];
        end
    end
endmodule
