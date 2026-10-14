`timescale 1ns / 1ps
// Standalone integer Bresenham rasterizer. Both endpoints are included.
// One command at a time. Pixels outside the viewport are suppressed.
// Input coordinates are signed integers, supported range -32768..32767.
module Line_Draw #(
    parameter integer SCREEN_WIDTH = 640,
    parameter integer SCREEN_HEIGHT = 480
) (
    input wire clk, rst,
    input wire in_valid,
    output wire in_ready,
    input wire signed [31:0] x0, y0, x1, y1,
    input wire [31:0] in_color,
    output wire out_valid,
    input wire out_ready,
    output wire signed [31:0] pixel_x, pixel_y,
    output wire [31:0] pixel_color,
    output wire busy,
    output reg done, error
);
    reg active;
    reg signed [31:0] current_x, current_y, end_x, end_y;
    reg signed [33:0] dx, dy;
    reg signed [34:0] error_acc;
    reg step_x_positive, step_y_positive;
    reg [31:0] color;
    wire signed [32:0] delta_x = {x1[31], x1} - {x0[31], x0};
    wire signed [32:0] delta_y = {y1[31], y1} - {y0[31], y0};
    wire signed [33:0] abs_dx = delta_x < 0 ?
        -$signed({delta_x[32], delta_x}) : $signed({delta_x[32], delta_x});
    wire signed [33:0] abs_dy = delta_y < 0 ?
        -$signed({delta_y[32], delta_y}) : $signed({delta_y[32], delta_y});
    wire supported = SCREEN_WIDTH > 0 && SCREEN_WIDTH <= 32768 &&
        SCREEN_HEIGHT > 0 && SCREEN_HEIGHT <= 32768 &&
        x0 >= -32'sd32768 && x0 <= 32'sd32767 &&
        y0 >= -32'sd32768 && y0 <= 32'sd32767 &&
        x1 >= -32'sd32768 && x1 <= 32'sd32767 &&
        y1 >= -32'sd32768 && y1 <= 32'sd32767;
    wire visible = current_x >= 0 && current_y >= 0 &&
        current_x < SCREEN_WIDTH && current_y < SCREEN_HEIGHT;
    wire signed [35:0] twice_error = $signed({error_acc[34], error_acc}) <<< 1;
    wire advance_x = twice_error >= -$signed({{2{dy[33]}}, dy});
    wire advance_y = twice_error <= $signed({{2{dx[33]}}, dx});
    assign in_ready = !rst && !active;
    assign busy = active;
    assign out_valid = !rst && active && visible;
    assign pixel_x = current_x;
    assign pixel_y = current_y;
    assign pixel_color = color;

    always @(posedge clk) begin
        if (rst) begin
            active <= 0; done <= 0; error <= 0;
            current_x <= 0; current_y <= 0; end_x <= 0; end_y <= 0;
            dx <= 0; dy <= 0; error_acc <= 0; color <= 0;
            step_x_positive <= 0; step_y_positive <= 0;
        end else begin
            done <= 0;
            if (in_valid && in_ready) begin
                error <= !supported;
                if (!supported) done <= 1;
                else begin
                    active <= 1;
                    current_x <= x0; current_y <= y0;
                    end_x <= x1; end_y <= y1;
                    dx <= abs_dx; dy <= abs_dy;
                    error_acc <= $signed({abs_dx[33], abs_dx}) -
                                 $signed({abs_dy[33], abs_dy});
                    step_x_positive <= x0 < x1;
                    step_y_positive <= y0 < y1;
                    color <= in_color;
                end
            end else if (active && (!visible || out_ready)) begin
                if (current_x == end_x && current_y == end_y) begin
                    active <= 0; done <= 1;
                end else begin
                    if (advance_x) current_x <= step_x_positive ? current_x + 32'sd1 : current_x - 32'sd1;
                    if (advance_y) current_y <= step_y_positive ? current_y + 32'sd1 : current_y - 32'sd1;
                    // Both tests use the SAME old error value. A diagonal step
                    // updates the accumulator once with both contributions.
                    case ({advance_x, advance_y})
                        2'b10: error_acc <= error_acc - $signed({dy[33], dy});
                        2'b01: error_acc <= error_acc + $signed({dx[33], dx});
                        2'b11: error_acc <= error_acc + $signed({dx[33], dx}) - $signed({dy[33], dy});
                        default: begin end
                    endcase
                end
            end
        end
    end
endmodule
