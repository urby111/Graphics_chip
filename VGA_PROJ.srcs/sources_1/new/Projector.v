`timescale 1ns / 1ps
// Camera-relative position -> pitch -> yaw -> perspective division.
// Input coordinates: signed 16 bits, 8 fractional bits (1.0 = 256).
// x_2d/y_2d: signed 32 bits, 16 fractional bits (1.0 = 65536).
// Accepts a vertex on EVERY edge with in_valid=1. No input backpressure.
// An input captured on edge N produces out_valid on edge N+41.
// All arithmetic and divider stages are registered; only the trig ROMs
// are separate modules. See docs/projector.md for the complete contract.
module Projector (
    input  wire               clk,
    input  wire               rst,        // synchronous, active high; flushes pipeline
    input  wire               in_valid,
    input  wire signed [15:0] vertex_x,
    input  wire signed [15:0] vertex_y,
    input  wire signed [15:0] vertex_z,
    input  wire signed [15:0] camera_x,
    input  wire signed [15:0] camera_y,
    input  wire signed [15:0] camera_z,
    input  wire [8:0]         pitch_deg,
    input  wire [8:0]         yaw_deg,
    output reg                out_valid,
    output reg                clipped,    // rotated z <= 0; x_2d/y_2d are zero
    output reg                overflow,   // positive-depth result saturated
    output reg signed [31:0]  x_2d,
    output reg signed [31:0]  y_2d,
    output reg signed [18:0]  depth       // rotated z, still 8 fractional bits
);
    localparam DIV_STEPS = 35; // 19 numerator magnitude bits + 16 fractional bits

    wire signed [15:0] pitch_sin, pitch_cos, yaw_sin, yaw_cos;
    sin_cos_lut pitch_lut (
        .clk(clk), .angle_deg(pitch_deg),
        .sin_value(pitch_sin), .cos_value(pitch_cos)
    );
    sin_cos_lut yaw_lut (
        .clk(clk), .angle_deg(yaw_deg),
        .sin_value(yaw_sin), .cos_value(yaw_cos)
    );

    reg [4:0] valid_math;
    reg signed [18:0] rel_x, rel_y, rel_z;
    reg signed [34:0] py_cos, pz_sin, py_sin, pz_cos;
    reg signed [18:0] pitch_x_delay, pitch_x, pitch_y, pitch_z;
    reg signed [15:0] yaw_sin_delay1, yaw_cos_delay1;
    reg signed [15:0] yaw_sin_delay2, yaw_cos_delay2;
    reg signed [34:0] yx_cos, yz_sin, yx_sin, yz_cos;
    reg signed [18:0] yaw_y_delay, rotated_x, rotated_y, rotated_z;

    // Add a guard bit BEFORE adding/subtracting the signed products.
    // Bits below 15 are discarded when returning to coordinate scale.
    // Upper bits 35:34 are redundant sign bits for the 16-bit input range:
    // translation plus two rotations stays safely inside signed 19 bits.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [35:0] pitch_y_sum = {py_cos[34], py_cos} - {pz_sin[34], pz_sin};
    wire signed [35:0] pitch_z_sum = {py_sin[34], py_sin} + {pz_cos[34], pz_cos};
    wire signed [35:0] yaw_x_sum = {yx_cos[34], yx_cos} - {yz_sin[34], yz_sin};
    wire signed [35:0] yaw_z_sum = {yx_sin[34], yx_sin} + {yz_cos[34], yz_cos};
    /* verilator lint_on UNUSEDSIGNAL */

    always @(posedge clk) begin
        if (rst)
            valid_math <= 5'b0;
        else
            valid_math <= {valid_math[3:0], in_valid};

        // Stage 1: subtract camera, while both LUTs sample this vertex's angles.
        // Widen BEFORE subtraction; opposite-sign endpoints need 17 bits.
        rel_x <= {{3{vertex_x[15]}}, vertex_x} - {{3{camera_x[15]}}, camera_x};
        rel_y <= {{3{vertex_y[15]}}, vertex_y} - {{3{camera_y[15]}}, camera_y};
        rel_z <= {{3{vertex_z[15]}}, vertex_z} - {{3{camera_z[15]}}, camera_z};

        // Stage 2: pitch products. These LUT outputs belong to rel_x/y/z.
        py_cos <= rel_y * pitch_cos;
        pz_sin <= rel_z * pitch_sin;
        py_sin <= rel_y * pitch_sin;
        pz_cos <= rel_z * pitch_cos;
        pitch_x_delay <= rel_x;
        yaw_sin_delay1 <= yaw_sin;
        yaw_cos_delay1 <= yaw_cos;

        // Stage 3: pitch sums, arithmetic truncation by 15 fractional bits.
        pitch_x <= pitch_x_delay;
        pitch_y <= pitch_y_sum[33:15];
        pitch_z <= pitch_z_sum[33:15];
        yaw_sin_delay2 <= yaw_sin_delay1;
        yaw_cos_delay2 <= yaw_cos_delay1;

        // Stage 4: yaw products; delay the unchanged y along with them.
        yx_cos <= pitch_x * yaw_cos_delay2;
        yz_sin <= pitch_z * yaw_sin_delay2;
        yx_sin <= pitch_x * yaw_sin_delay2;
        yz_cos <= pitch_z * yaw_cos_delay2;
        yaw_y_delay <= pitch_y;

        // Stage 5: yaw sums, returning to 8 fractional coordinate bits.
        rotated_x <= yaw_x_sum[33:15];
        rotated_y <= yaw_y_delay;
        rotated_z <= yaw_z_sum[33:15];
    end

    // Unsigned magnitudes for two parallel, fully pipelined restoring dividers.
    // q starts as the numerator and shifts into the quotient, one bit per edge.
    reg [34:0] qx [0:DIV_STEPS];
    reg [34:0] qy [0:DIV_STEPS];
    reg [18:0] rx [0:DIV_STEPS];
    reg [18:0] ry [0:DIV_STEPS];
    reg [18:0] denominator [0:DIV_STEPS];
    reg signed [18:0] depth_pipe [0:DIV_STEPS];
    reg sign_x [0:DIV_STEPS];
    reg sign_y [0:DIV_STEPS];
    reg bad_depth [0:DIV_STEPS];
    reg div_valid [0:DIV_STEPS];

    wire [18:0] magnitude_x = rotated_x[18] ? (~rotated_x + 19'd1) : rotated_x;
    wire [18:0] magnitude_y = rotated_y[18] ? (~rotated_y + 19'd1) : rotated_y;

    always @(posedge clk) begin
        // Stage 6: |numerator| << 16 gives the projected Q16.16 scale.
        qx[0] <= {magnitude_x, 16'b0};
        qy[0] <= {magnitude_y, 16'b0};
        rx[0] <= 19'b0;
        ry[0] <= 19'b0;
        // Invalid depth takes a harmless division path and is flagged later.
        denominator[0] <= (rotated_z > 19'sd0) ? rotated_z : 19'd1;
        depth_pipe[0] <= rotated_z;
        sign_x[0] <= rotated_x[18];
        sign_y[0] <= rotated_y[18];
        bad_depth[0] <= (rotated_z <= 19'sd0);
        div_valid[0] <= !rst && valid_math[4];
    end

    genvar i;
    generate
        for (i = 0; i < DIV_STEPS; i = i + 1) begin : divide_bit
            wire [19:0] trial_x = {rx[i], qx[i][34]};
            wire [19:0] trial_y = {ry[i], qy[i][34]};
            // The top bit is a borrow flag. One subtract and mux per stage.
            // Bit 19 is redundant in the selected remainder (remainder < divisor).
            /* verilator lint_off UNUSEDSIGNAL */
            wire [20:0] diff_x = {1'b0, trial_x} - {2'b0, denominator[i]};
            wire [20:0] diff_y = {1'b0, trial_y} - {2'b0, denominator[i]};
            /* verilator lint_on UNUSEDSIGNAL */
            always @(posedge clk) begin
                rx[i+1] <= diff_x[20] ? trial_x[18:0] : diff_x[18:0];
                ry[i+1] <= diff_y[20] ? trial_y[18:0] : diff_y[18:0];
                qx[i+1] <= {qx[i][33:0], !diff_x[20]};
                qy[i+1] <= {qy[i][33:0], !diff_y[20]};
                denominator[i+1] <= denominator[i];
                depth_pipe[i+1] <= depth_pipe[i];
                sign_x[i+1] <= sign_x[i];
                sign_y[i+1] <= sign_y[i];
                bad_depth[i+1] <= bad_depth[i];
                div_valid[i+1] <= !rst && div_valid[i];
            end
        end
    endgenerate

    function [31:0] signed_saturate;
        input [34:0] magnitude;
        input negative;
        begin
            if (negative)
                signed_saturate = (magnitude > 35'd2147483648) ?
                                  32'h80000000 : (~magnitude[31:0] + 32'd1);
            else
                signed_saturate = (magnitude > 35'd2147483647) ?
                                  32'h7FFFFFFF : magnitude[31:0];
        end
    endfunction

    // Stage 42: restore signs, saturate and publish flags with the same vertex.
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            clipped <= 1'b0;
            overflow <= 1'b0;
            x_2d <= 32'sd0;
            y_2d <= 32'sd0;
            depth <= 19'sd0;
        end else begin
            out_valid <= div_valid[DIV_STEPS];
            depth <= depth_pipe[DIV_STEPS];
            clipped <= bad_depth[DIV_STEPS];
            overflow <= !bad_depth[DIV_STEPS] &&
                ((qx[DIV_STEPS] > (sign_x[DIV_STEPS] ? 35'd2147483648 : 35'd2147483647)) ||
                 (qy[DIV_STEPS] > (sign_y[DIV_STEPS] ? 35'd2147483648 : 35'd2147483647)));
            x_2d <= bad_depth[DIV_STEPS] ? 32'd0 : signed_saturate(qx[DIV_STEPS], sign_x[DIV_STEPS]);
            y_2d <= bad_depth[DIV_STEPS] ? 32'd0 : signed_saturate(qy[DIV_STEPS], sign_y[DIV_STEPS]);
        end
    end
endmodule
