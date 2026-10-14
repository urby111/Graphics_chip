`timescale 1ns / 1ps
// Convert Projector's signed Q16.16 x_2d/y_2d to screen coordinates.
// Defaults: 640x480, 90-degree horizontal FOV, square pixels.
// For this FOV, focal length = WIDTH / (2*tan(45 degrees)) = 320 pixels.
// When changing the FOV, set FOCAL_PIXELS to WIDTH/(2*tan(FOV/2)).
// One registered stage: inputs sampled on edge N appear after edge N.
module Projector_To_Frame #(
    parameter signed [63:0] WIDTH = 64'sd640,
    parameter signed [63:0] HEIGHT = 64'sd480,
    parameter signed [63:0] FOCAL_PIXELS = 64'sd320
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire               clipped,
    input  wire               overflow,
    input  wire signed [31:0] x_2d,
    input  wire signed [31:0] y_2d,
    input  wire signed [18:0] depth,
    output reg                out_valid,
    output reg                out_clipped,
    output reg                out_overflow,
    output reg                in_frame,
    output reg signed [31:0] frame_x,
    output reg signed [31:0] frame_y,
    output reg signed [18:0] out_depth
);
    // Keep the Q16 fraction until the final shift. The wide intermediate
    // prevents wraparound even for Projector's saturated 32-bit outputs.
    localparam signed [63:0] CENTER_X_Q16 = (WIDTH / 64'sd2) * 64'sd65536;
    localparam signed [63:0] CENTER_Y_Q16 = (HEIGHT / 64'sd2) * 64'sd65536;
    wire signed [63:0] x_pixels =
        (CENTER_X_Q16 + ($signed(x_2d) * FOCAL_PIXELS)) >>> 16;
    wire signed [63:0] y_pixels =
        (CENTER_Y_Q16 - ($signed(y_2d) * FOCAL_PIXELS)) >>> 16;

    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_clipped <= 1'b0;
            out_overflow <= 1'b0;
            in_frame <= 1'b0;
            frame_x <= 32'sd0;
            frame_y <= 32'sd0;
            out_depth <= 19'sd0;
        end else begin
            out_valid <= in_valid;
            out_clipped <= clipped;
            out_overflow <= overflow;
            frame_x <= x_pixels[31:0];
            frame_y <= y_pixels[31:0];
            out_depth <= depth;
            // Keep off-screen coordinates; a later triangle rasterizer may
            // still need them to draw the visible portion of a triangle.
            in_frame <= in_valid && !clipped && !overflow &&
                        (x_pixels >= 64'sd0) && (x_pixels < WIDTH) &&
                        (y_pixels >= 64'sd0) && (y_pixels < HEIGHT);
        end
    end
endmodule
