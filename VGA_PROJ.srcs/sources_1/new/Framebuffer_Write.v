`timescale 1ns / 1ps
// Integer screen point -> a red 32-bit RAM/DDR write request.
// Byte address = selected framebuffer offset + y*stride_bytes + x*4.
// External memory accepts a write on wr_valid && wr_ready. No AXI implied.
module Framebuffer_Write (
    input wire clk, rst,
    input wire in_valid,
    output wire in_ready,
    input wire signed [31:0] x2d, y2d,
    input wire in_frame, in_rejected,
    input wire buffer_select,
    input wire [15:0] screen_width, screen_height,
    input wire [31:0] buffer_a_offset, buffer_b_offset,
    input wire [31:0] stride_bytes, region_bytes,

    output wire wr_valid,
    input wire wr_ready,
    output wire [31:0] wr_addr,
    output wire [31:0] wr_data,
    output wire [3:0] wr_strb,
    output wire wr_buffer_select,
    output wire dropped,
    output wire busy
);
    reg [3:0] valid_pipe;
    reg good_0, good_1, good_2, good_3;
    reg selected_0, selected_1, selected_2, selected_3;
    wire advance = !valid_pipe[3] || !good_3 || wr_ready;

    assign in_ready = !rst && advance;
    assign wr_valid = !rst && valid_pipe[3] && good_3;
    assign dropped = !rst && valid_pipe[3] && !good_3;
    assign busy = |valid_pipe;
    assign wr_data = 32'h00ff0000;
    assign wr_strb = 4'b1111;
    assign wr_buffer_select = selected_3;

    reg [63:0] row_bytes_0, column_bytes_0, allocation_bytes_0;
    reg [63:0] a_0, b_0, region_0;
    reg [63:0] end_a_1, end_b_1, a_1, b_1, region_1, pixel_offset_1;
    reg [63:0] address_2;
    reg [31:0] address_3;
    assign wr_addr = address_3;

    always @(posedge clk) begin
        if (rst) valid_pipe <= 4'b0;
        else if (advance) begin
            valid_pipe <= {valid_pipe[2:0], in_valid && in_ready};

            // Stage 0: products and validation. Signed negatives cannot write.
            row_bytes_0 <= $unsigned(y2d) * stride_bytes;
            column_bytes_0 <= {30'b0, x2d, 2'b0};
            allocation_bytes_0 <= {16'b0, screen_height} * stride_bytes;
            a_0 <= {32'b0, buffer_a_offset};
            b_0 <= {32'b0, buffer_b_offset};
            region_0 <= {32'b0, region_bytes};
            selected_0 <= buffer_select;
            good_0 <= in_frame && !in_rejected && (x2d >= 0) && (y2d >= 0) &&
                ($unsigned(x2d) < {16'b0, screen_width}) &&
                ($unsigned(y2d) < {16'b0, screen_height}) &&
                (screen_width != 0) && (screen_height != 0) &&
                (stride_bytes >= {14'b0, screen_width, 2'b0}) &&
                (stride_bytes[1:0] == 0) && (buffer_a_offset[1:0] == 0) &&
                (buffer_b_offset[1:0] == 0);

            // Stage 1: allocation ends and offset within the selected buffer.
            end_a_1 <= a_0 + allocation_bytes_0;
            end_b_1 <= b_0 + allocation_bytes_0;
            pixel_offset_1 <= row_bytes_0 + column_bytes_0;
            a_1 <= a_0;
            b_1 <= b_0;
            region_1 <= region_0;
            selected_1 <= selected_0;
            good_1 <= good_0;

            // Stage 2: allow only distinct, non-overlapping, in-region buffers.
            address_2 <= (selected_1 ? b_1 : a_1) + pixel_offset_1;
            good_2 <= good_1 && (end_a_1 <= region_1) && (end_b_1 <= region_1) &&
                      ((end_a_1 <= b_1) || (end_b_1 <= a_1));
            selected_2 <= selected_1;

            // Stage 3: full write transaction held stable until acknowledged.
            good_3 <= good_2 && (address_2[63:32] == 0);
            address_3 <= address_2[31:0];
            selected_3 <= selected_2;
        end
    end
endmodule
