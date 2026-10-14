`timescale 1ns / 1ps

module tb_Projector;

    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz simulation clock

    reg rst = 1;
    reg in_valid = 0;

    reg signed [15:0] vertex_x = 0;
    reg signed [15:0] vertex_y = 0;
    reg signed [15:0] vertex_z = 0;

    reg signed [15:0] camera_x = 0;
    reg signed [15:0] camera_y = 0;
    reg signed [15:0] camera_z = 0;

    reg [8:0] pitch_deg = 0;
    reg [8:0] yaw_deg = 0;

    wire out_valid, clipped, overflow;
    wire signed [31:0] x_2d, y_2d;
    wire signed [18:0] depth;

    Projector dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .vertex_x(vertex_x),
        .vertex_y(vertex_y),
        .vertex_z(vertex_z),
        .camera_x(camera_x),
        .camera_y(camera_y),
        .camera_z(camera_z),
        .pitch_deg(pitch_deg),
        .yaw_deg(yaw_deg),
        .out_valid(out_valid),
        .clipped(clipped),
        .overflow(overflow),
        .x_2d(x_2d),
        .y_2d(y_2d),
        .depth(depth)
    );

    // Submit the current inputs, wait for the result, and check it.
    task check_result;
        input [8*40-1:0] test_name;
        input signed [31:0] expected_x;
        input signed [31:0] expected_y;
        input signed [18:0] expected_depth;
        input expected_clipped;

        begin
            @(negedge clk);
            in_valid = 1;

            @(negedge clk);
            in_valid = 0;

            wait (out_valid === 1'b1);
            #1;

            $display("\n--- %0s ---", test_name);

            $display("EXPECTED raw: x=%0d y=%0d depth=%0d clipped=%0b",
                     expected_x, expected_y,
                     expected_depth, expected_clipped);

            $display("ACTUAL   raw: x=%0d y=%0d depth=%0d clipped=%0b",
                     x_2d, y_2d, depth, clipped);

            $display("EXPECTED decimal: x=%0.6f y=%0.6f depth=%0.6f",
                     $itor(expected_x) / 65536.0,
                     $itor(expected_y) / 65536.0,
                     $itor(expected_depth) / 256.0);

            $display("ACTUAL   decimal: x=%0.6f y=%0.6f depth=%0.6f",
                     $itor(x_2d) / 65536.0,
                     $itor(y_2d) / 65536.0,
                     $itor(depth) / 256.0);

            if (x_2d !== expected_x ||
                y_2d !== expected_y ||
                depth !== expected_depth ||
                clipped !== expected_clipped ||
                overflow !== 1'b0)
                $fatal(1, "FAIL: %0s", test_name);

            $display("PASS");
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        // Input coordinates: real value multiplied by 256.
        // Expected outputs include the LUT's fixed-point truncation.

        // TEST 1: (2,1,4) with no camera movement or rotation.
        // Ideal projection: x=2/4=0.5, y=1/4=0.25.
        vertex_x = 16'sd512;
        vertex_y = 16'sd256;
        vertex_z = 16'sd1024;

        check_result("No rotation",
                     32'sd32768, 32'sd16351, 19'sd1022, 1'b0);

        // TEST 2: move the camera one unit along X.
        // Relative position becomes (1,1,4).
        camera_x = 16'sd256;

        check_result("Camera moved along X",
                     32'sd16351, 32'sd16351, 19'sd1022, 1'b0);

        // TEST 3: pitch (0,4,1) by 90 degrees.
        // Ideal rotated position: (0,-1,4).
        camera_x = 0;
        vertex_x = 0;
        vertex_y = 16'sd1024;
        vertex_z = 16'sd256;
        pitch_deg = 9'd90;
        yaw_deg = 0;

        check_result("Pitch 90 degrees",
                     32'sd0, -32'sd16416, 19'sd1022, 1'b0);

        // TEST 4: yaw (4,0,1) by 90 degrees.
        // Ideal rotated position: (-1,0,4).
        vertex_x = 16'sd1024;
        vertex_y = 0;
        vertex_z = 16'sd256;
        pitch_deg = 0;
        yaw_deg = 9'd90;

        check_result("Yaw 90 degrees",
                     -32'sd16335, 32'sd0, 19'sd1023, 1'b0);

        // TEST 5: point behind the camera must be rejected.
        vertex_x = 16'sd512;
        vertex_y = 16'sd256;
        vertex_z = -16'sd1024;
        pitch_deg = 0;
        yaw_deg = 0;

        check_result("Behind the camera",
                     32'sd0, 32'sd0, -19'sd1024, 1'b1);

        $display("\nALL FIVE TESTS PASSED");
        $finish;
    end

    // Stop if the projector never produces a result.
    initial begin
        #5000;
        $fatal(1, "TIMEOUT: no result received");
    end

endmodule
