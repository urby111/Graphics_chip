`timescale 1ns / 1ps
// Standalone flat-color triangle rasterizer. Integer screen-space vertices;
// sample pixel centers with a top-left edge rule, accepting either winding.
// Coordinates outside -32768..32767 are rejected; no framebuffer/AXI inside.
module Triangle_Fill #(
    parameter integer SCREEN_WIDTH = 640,
    parameter integer SCREEN_HEIGHT = 480
) (
    input wire clk, rst,
    input wire in_valid,
    output wire in_ready,
    input wire signed [31:0] x0, y0, x1, y1, x2, y2,
    input wire [31:0] in_color,
    output wire out_valid,
    input wire out_ready,
    output wire signed [31:0] pixel_x, pixel_y,
    output wire [31:0] pixel_color,
    output wire busy,
    output reg done, error
);
    localparam IDLE=2'd0, SETUP=2'd1, INIT=2'd2, SCAN=2'd3;
    reg [1:0] state;
    reg signed [15:0] ax, ay, bx, by, cx, cy;
    reg [15:0] current_x, current_y, first_x, last_x, last_y;
    reg [31:0] color;
    reg inverted, include0, include1, include2;
    reg signed [35:0] e0, e1, e2, row0, row1, row2;
    reg signed [18:0] sx0, sx1, sx2, sy0, sy1, sy2;
    wire signed [16:0] dx0 = {bx[15], bx} - {ax[15], ax};
    wire signed [16:0] dy0 = {by[15], by} - {ay[15], ay};
    wire signed [16:0] dx1 = {cx[15], cx} - {bx[15], bx};
    wire signed [16:0] dy1 = {cy[15], cy} - {by[15], by};
    wire signed [16:0] dx2 = {ax[15], ax} - {cx[15], cx};
    wire signed [16:0] dy2 = {ay[15], ay} - {cy[15], cy};
    wire signed [16:0] acx = {cx[15], cx} - {ax[15], ax};
    wire signed [16:0] acy = {cy[15], cy} - {ay[15], ay};
    wire signed [34:0] area = dx0 * acy - dy0 * acx;

    function signed [31:0] min3;
        input signed [15:0] a, b, c;
        reg signed [15:0] m;
        begin m = a < b ? a : b; if (c < m) m = c; min3 = {{16{m[15]}}, m}; end
    endfunction
    function signed [31:0] max3;
        input signed [15:0] a, b, c;
        reg signed [15:0] m;
        begin m = a > b ? a : b; if (c > m) m = c; max3 = {{16{m[15]}}, m}; end
    endfunction
    wire signed [31:0] low_x = min3(ax, bx, cx);
    wire signed [31:0] high_x = max3(ax, bx, cx);
    wire signed [31:0] low_y = min3(ay, by, cy);
    wire signed [31:0] high_y = max3(ay, by, cy);
    wire [15:0] clipped_low_x = low_x < 0 ? 16'd0 : low_x[15:0];
    wire [15:0] clipped_low_y = low_y < 0 ? 16'd0 : low_y[15:0];
    wire [15:0] clipped_high_x = high_x >= SCREEN_WIDTH ? SCREEN_WIDTH[15:0]-16'd1 : high_x[15:0];
    wire [15:0] clipped_high_y = high_y >= SCREEN_HEIGHT ? SCREEN_HEIGHT[15:0]-16'd1 : high_y[15:0];
    function signed [35:0] wide_step;
        input signed [18:0] value;
        begin wide_step = {{17{value[18]}}, value}; end
    endfunction

    // E = (B-A) cross (2*pixel_center - 2*A). 17-bit edge deltas,
    // 18-bit sample deltas and 36-bit edges preserve the whole supported range.
    function signed [35:0] edge_at;
        input signed [15:0] a_x, a_y, b_x, b_y;
        input [15:0] p_x, p_y;
        reg signed [16:0] delta_x, delta_y;
        reg signed [17:0] sample_x, sample_y, doubled_ax, doubled_ay;
        begin
            delta_x = {b_x[15], b_x} - {a_x[15], a_x};
            delta_y = {b_y[15], b_y} - {a_y[15], a_y};
            doubled_ax = $signed({{2{a_x[15]}}, a_x}) <<< 1;
            doubled_ay = $signed({{2{a_y[15]}}, a_y}) <<< 1;
            sample_x = $signed({1'b0, p_x, 1'b1}) - doubled_ax;
            sample_y = $signed({1'b0, p_y, 1'b1}) - doubled_ay;
            edge_at = delta_x * sample_y - delta_y * sample_x;
        end
    endfunction
    function is_top_left;
        input signed [16:0] delta_x, delta_y;
        input reverse_edge;
        begin
            is_top_left = reverse_edge ?
                (delta_y > 0 || (delta_y == 0 && delta_x < 0)) :
                (delta_y < 0 || (delta_y == 0 && delta_x > 0));
        end
    endfunction
    wire signed [35:0] initial0 = edge_at(ax, ay, bx, by, current_x, current_y);
    wire signed [35:0] initial1 = edge_at(bx, by, cx, cy, current_x, current_y);
    wire signed [35:0] initial2 = edge_at(cx, cy, ax, ay, current_x, current_y);
    wire covered = (e0 > 0 || (e0 == 0 && include0)) &&
                  (e1 > 0 || (e1 == 0 && include1)) &&
                  (e2 > 0 || (e2 == 0 && include2));
    wire supported = SCREEN_WIDTH > 0 && SCREEN_WIDTH <= 32768 &&
        SCREEN_HEIGHT > 0 && SCREEN_HEIGHT <= 32768 &&
        x0 >= -32'sd32768 && x0 <= 32'sd32767 &&
        y0 >= -32'sd32768 && y0 <= 32'sd32767 &&
        x1 >= -32'sd32768 && x1 <= 32'sd32767 &&
        y1 >= -32'sd32768 && y1 <= 32'sd32767 &&
        x2 >= -32'sd32768 && x2 <= 32'sd32767 &&
        y2 >= -32'sd32768 && y2 <= 32'sd32767;
    assign in_ready = !rst && state == IDLE;
    assign busy = state != IDLE;
    assign out_valid = !rst && state == SCAN && covered;
    assign pixel_x = $signed({16'b0, current_x});
    assign pixel_y = $signed({16'b0, current_y});
    assign pixel_color = color;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; done <= 0; error <= 0;
            ax<=0; ay<=0; bx<=0; by<=0; cx<=0; cy<=0; color<=0;
            current_x<=0; current_y<=0; first_x<=0; last_x<=0; last_y<=0;
            inverted<=0; include0<=0; include1<=0; include2<=0;
            e0<=0; e1<=0; e2<=0; row0<=0; row1<=0; row2<=0;
            sx0<=0; sx1<=0; sx2<=0; sy0<=0; sy1<=0; sy2<=0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (in_valid) begin
                    error <= !supported;
                    if (!supported) done <= 1;
                    else begin
                        ax<=x0[15:0]; ay<=y0[15:0]; bx<=x1[15:0]; by<=y1[15:0];
                        cx<=x2[15:0]; cy<=y2[15:0]; color<=in_color;
                        state<=SETUP;
                    end
                end
                SETUP: if (area == 0 || high_x < 0 || high_y < 0 ||
                            low_x >= SCREEN_WIDTH || low_y >= SCREEN_HEIGHT) begin
                    state<=IDLE; done<=1;
                end else begin
                    first_x<=clipped_low_x; current_x<=clipped_low_x;
                    current_y<=clipped_low_y; last_x<=clipped_high_x;
                    last_y<=clipped_high_y; inverted<=area<0;
                    include0<=is_top_left(dx0, dy0, area<0);
                    include1<=is_top_left(dx1, dy1, area<0);
                    include2<=is_top_left(dx2, dy2, area<0);
                    sx0<=area<0 ? ($signed({{2{dy0[16]}}, dy0}) <<< 1) : -($signed({{2{dy0[16]}}, dy0}) <<< 1);
                    sx1<=area<0 ? ($signed({{2{dy1[16]}}, dy1}) <<< 1) : -($signed({{2{dy1[16]}}, dy1}) <<< 1);
                    sx2<=area<0 ? ($signed({{2{dy2[16]}}, dy2}) <<< 1) : -($signed({{2{dy2[16]}}, dy2}) <<< 1);
                    sy0<=area<0 ? -($signed({{2{dx0[16]}}, dx0}) <<< 1) : ($signed({{2{dx0[16]}}, dx0}) <<< 1);
                    sy1<=area<0 ? -($signed({{2{dx1[16]}}, dx1}) <<< 1) : ($signed({{2{dx1[16]}}, dx1}) <<< 1);
                    sy2<=area<0 ? -($signed({{2{dx2[16]}}, dx2}) <<< 1) : ($signed({{2{dx2[16]}}, dx2}) <<< 1);
                    state<=INIT;
                end
                INIT: begin
                    e0<=inverted ? -initial0 : initial0; row0<=inverted ? -initial0 : initial0;
                    e1<=inverted ? -initial1 : initial1; row1<=inverted ? -initial1 : initial1;
                    e2<=inverted ? -initial2 : initial2; row2<=inverted ? -initial2 : initial2;
                    state<=SCAN;
                end
                SCAN: if (!covered || out_ready) begin
                    if (current_x == last_x && current_y == last_y) begin state<=IDLE; done<=1; end
                    else if (current_x == last_x) begin
                        current_x<=first_x; current_y<=current_y+16'd1;
                        row0<=row0+wide_step(sy0); e0<=row0+wide_step(sy0);
                        row1<=row1+wide_step(sy1); e1<=row1+wide_step(sy1);
                        row2<=row2+wide_step(sy2); e2<=row2+wide_step(sy2);
                    end else begin
                        current_x<=current_x+16'd1;
                        e0<=e0+wide_step(sx0); e1<=e1+wide_step(sx1); e2<=e2+wide_step(sx2);
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
