`timescale 1ns / 1ps
module tb_Projector_To_Frame;
    reg clk = 0;
    always #5 clk <= ~clk;
    reg rst = 1;
    reg in_valid = 0;
    reg clipped = 0;
    reg overflow = 0;
    reg signed [31:0] x_2d = 0;
    reg signed [31:0] y_2d = 0;
    reg signed [18:0] depth = 0;
    wire out_valid, out_clipped, out_overflow, in_frame;
    wire signed [31:0] frame_x, frame_y;
    wire signed [18:0] out_depth;

    Projector_To_Frame dut (.*);

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        in_valid = 1;
        x_2d = 32'sd32768;  // 0.5 in Q16.16
        y_2d = 32'sd16384;  // 0.25 in Q16.16
        depth = 19'sd1024;
        @(posedge clk);
        #1;
        if (!out_valid || !in_frame || out_overflow || frame_x != 480 || frame_y != 160 || out_depth != 1024)
            $fatal(1, "Expected (480,160), got (%0d,%0d)", frame_x, frame_y);

        @(negedge clk);
        x_2d = 32'sd131072; // 2.0: outside the right edge
        y_2d = 0;
        @(posedge clk);
        #1;
        if (!out_valid || in_frame || frame_x != 960 || frame_y != 240)
            $fatal(1, "Expected off-screen (960,240), got (%0d,%0d)", frame_x, frame_y);

        @(negedge clk);
        clipped = 1;
        @(posedge clk);
        #1;
        if (!out_valid || !out_clipped || in_frame)
            $fatal(1, "Clipped point must not be in frame");

        $display("PASS: projected coordinates become frame coordinates");
        $finish;
    end
endmodule
