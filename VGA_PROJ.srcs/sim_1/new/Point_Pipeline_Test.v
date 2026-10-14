`timescale 1ns / 1ps
// Test harness only. mode 0: matrix results -> screen -> writer.
// mode 1: object vertices -> Matrix_Vertex -> screen -> writer.
// mode 2: integer pixels -> writer (exercise its independent bounds checks).
module Point_Pipeline_Test (
    input wire clk, rst,
    input wire [1:0] mode,
    input wire matrix_valid,
    output wire matrix_ready, matrix_loaded,
    input wire [31:0] matrix_data,
    input wire point_valid,
    output wire point_ready,
    input wire signed [31:0] point_x, point_y, point_z, point_w,
    input wire [3:0] point_overflow,
    input wire point_in_frame, buffer_select,
    input wire [15:0] width, height,
    input wire signed [31:0] near_q16,
    input wire [31:0] a_offset, b_offset, stride, region_bytes,
    output wire screen_valid, screen_ready,
    output wire signed [31:0] screen_x, screen_y, screen_depth,
    output wire screen_in_frame, screen_rejected, screen_buffer,
    output wire [15:0] result_width, result_height,
    output wire screen_busy, writer_busy,
    output wire wr_valid,
    input wire wr_ready,
    output wire [31:0] wr_addr, wr_data,
    output wire [3:0] wr_strb,
    output wire wr_buffer, dropped
);
    wire m_valid, m_ready, vertex_ready, projection_ready, pixel_ready;
    wire signed [31:0] mx, my, mz, mw;
    wire [3:0] m_overflow;
    Matrix_Vertex matrix_unit (
        .clk(clk), .rst(rst), .matrix_valid(matrix_valid),
        .matrix_ready(matrix_ready), .matrix_data(matrix_data), .matrix_loaded(matrix_loaded),
        .vertex_valid(point_valid && mode == 1), .vertex_ready(vertex_ready),
        .vertex_x(point_x), .vertex_y(point_y), .vertex_z(point_z),
        .out_valid(m_valid), .out_ready(m_ready),
        .result_x(mx), .result_y(my), .result_z(mz), .result_w(mw), .out_overflow(m_overflow)
    );
    assign m_ready = mode == 1 && projection_ready;
    assign point_ready = mode == 1 ? vertex_ready :
                         mode == 2 ? pixel_ready : projection_ready;
    Screen_Position projection (
        .clk(clk), .rst(rst),
        .in_valid(mode == 1 ? m_valid : (mode == 0 && point_valid)),
        .in_ready(projection_ready),
        .in_x(mode == 1 ? mx : point_x), .in_y(mode == 1 ? my : point_y),
        .in_z(mode == 1 ? mz : point_z), .in_w(mode == 1 ? mw : point_w),
        .in_overflow(mode == 1 ? m_overflow : point_overflow),
        .screen_width(width), .screen_height(height), .near_q16(near_q16),
        .buffer_select(buffer_select), .out_valid(screen_valid), .out_ready(screen_ready),
        .x2d(screen_x), .y2d(screen_y), .out_depth(screen_depth),
        .out_in_frame(screen_in_frame), .out_rejected(screen_rejected),
        .out_buffer_select(screen_buffer), .out_width(result_width), .out_height(result_height),
        .busy(screen_busy)
    );
    assign screen_ready = mode != 2 && pixel_ready;
    Framebuffer_Write writer (
        .clk(clk), .rst(rst), .in_valid(mode == 2 ? point_valid : screen_valid),
        .in_ready(pixel_ready), .x2d(mode == 2 ? point_x : screen_x),
        .y2d(mode == 2 ? point_y : screen_y),
        .in_frame(mode == 2 ? point_in_frame : screen_in_frame),
        .in_rejected(mode == 2 ? (|point_overflow) : screen_rejected),
        .buffer_select(mode == 2 ? buffer_select : screen_buffer),
        .screen_width(mode == 2 ? width : result_width),
        .screen_height(mode == 2 ? height : result_height),
        .buffer_a_offset(a_offset), .buffer_b_offset(b_offset),
        .stride_bytes(stride), .region_bytes(region_bytes),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_buffer_select(wr_buffer),
        .dropped(dropped), .busy(writer_busy)
    );
endmodule
