`timescale 1ns / 1ps
// Complete red-point demo. CPU supplies a matrix (camera/object/view combined)
// and XYZ vertices. Commands: 0=CLEAR, 1=DRAW vertex_count, 2=PRESENT at vblank.
// Fixed 640x480 output; matrix/vertex coordinates and near_q16 use Q16.16.
module GPU_Pipeline (
    input wire clk, rst,
    input wire matrix_valid,
    output wire matrix_ready, matrix_loaded,
    input wire signed [31:0] matrix_data,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [1:0] cmd,
    input wire buffer_select,
    input wire [31:0] vertex_count,
    input wire signed [31:0] near_q16,
    input wire vertex_valid,
    output wire vertex_ready,
    input wire signed [31:0] vertex_x, vertex_y, vertex_z,
    output wire busy,
    output reg done, error,
    output reg front_buffer, display_enabled,
    output reg hsync, vsync,
    output wire [3:0] vga_r, vga_g, vga_b,
    // Optional capture/debug outputs, synchronized to the displayed pixel.
    output reg scan_valid,
    output reg [18:0] scan_addr
);
    localparam IDLE=2'd0, CLEAR=2'd1, DRAW=2'd2, PRESENT=2'd3;
    reg [1:0] state;
    reg target_buffer;
    reg [1:0] initialized;
    reg [18:0] clear_index;
    reg [31:0] remaining;
    reg [6:0] in_flight;
    reg signed [31:0] active_near;
    wire m_load_ready, m_vertex_ready, m_valid, m_ready;
    wire signed [31:0] mx, my, mz, mw;
    wire [3:0] m_overflow;
    wire p_valid, p_ready, p_inside, p_rejected, p_buffer;
    wire signed [31:0] px, py, unused_depth;
    wire [15:0] p_width, p_height;
    wire unused_projection_busy, unused_writer_busy, unused_write_buffer;
    wire wr_valid, dropped;
    wire [31:0] wr_addr, wr_data;
    wire [3:0] wr_strb;
    wire accept_vertex = vertex_valid && vertex_ready;
    wire finish_vertex = wr_valid || dropped; // local RAM always accepts writes
    assign busy = state != IDLE;
    // Matrix loading has priority; DRAW cannot start with a partial matrix.
    assign matrix_ready = state == IDLE && m_load_ready;
    assign cmd_ready = !rst && state == IDLE && !matrix_valid &&
                       (cmd != 2'd1 || matrix_loaded);
    assign vertex_ready = state == DRAW && remaining != 0 && m_vertex_ready;

    Matrix_Vertex transform (
        .clk(clk), .rst(rst), .matrix_valid(matrix_valid && state == IDLE),
        .matrix_ready(m_load_ready), .matrix_data(matrix_data), .matrix_loaded(matrix_loaded),
        .vertex_valid(vertex_valid && state == DRAW && remaining != 0),
        .vertex_ready(m_vertex_ready), .vertex_x(vertex_x), .vertex_y(vertex_y), .vertex_z(vertex_z),
        .out_valid(m_valid), .out_ready(m_ready), .result_x(mx), .result_y(my),
        .result_z(mz), .result_w(mw), .out_overflow(m_overflow)
    );
    Screen_Position projection (
        .clk(clk), .rst(rst), .in_valid(m_valid), .in_ready(m_ready),
        .in_x(mx), .in_y(my), .in_z(mz), .in_w(mw), .in_overflow(m_overflow),
        .screen_width(16'd640), .screen_height(16'd480), .near_q16(active_near),
        .buffer_select(target_buffer), .out_valid(p_valid), .out_ready(p_ready),
        .x2d(px), .y2d(py), .out_depth(unused_depth), .out_in_frame(p_inside),
        .out_rejected(p_rejected), .out_buffer_select(p_buffer),
        .out_width(p_width), .out_height(p_height), .busy(unused_projection_busy)
    );
    Framebuffer_Write writer (
        .clk(clk), .rst(rst), .in_valid(p_valid), .in_ready(p_ready),
        .x2d(px), .y2d(py), .in_frame(p_inside), .in_rejected(p_rejected),
        .buffer_select(p_buffer), .screen_width(p_width), .screen_height(p_height),
        .buffer_a_offset(32'd0), .buffer_b_offset(32'd1228800),
        .stride_bytes(32'd2560), .region_bytes(32'd2457600),
        .wr_valid(wr_valid), .wr_ready(1'b1), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_strb(wr_strb), .wr_buffer_select(unused_write_buffer),
        .dropped(dropped), .busy(unused_writer_busy)
    );

    // VGA uses a clock enable: the entire design stays on the input clock.
    // One pixel each four clocks (25 MHz with a 100 MHz input, as in the font demo).
    reg [1:0] pixel_div;
    reg [9:0] h, v;
    wire pixel_enable = pixel_div == 2'd3;
    wire visible = h < 10'd640 && v < 10'd480;
    wire [18:0] row = {9'b0, v};
    wire [18:0] read_addr = visible ? (row << 9) + (row << 7) + {9'b0,h} : 19'd0;
    wire vblank_start = pixel_enable && h == 0 && v == 10'd480;
    reg visible_delay;
    wire red_pixel;
    wire ram_write = !rst && ((state == CLEAR) ||
                     (wr_valid && wr_strb == 4'hf && wr_addr < 32'd2457600));
    wire [19:0] ram_write_index = state == CLEAR ?
        {1'b0, clear_index} + (target_buffer ? 20'd307200 : 20'd0) : wr_addr[21:2];
    System_Memory #(.GPU_MODE(1)) framebuffer (
        .clk(clk), .addr(read_addr), .dout(red_pixel), .read_buffer(front_buffer),
        .wr_en(ram_write), .wr_addr(ram_write_index),
        .wr_data(state != CLEAR && wr_data == 32'h00ff0000)
    );
    assign vga_r = display_enabled && visible_delay && red_pixel ? 4'hf : 4'h0;
    assign vga_g = 4'h0;
    assign vga_b = 4'h0;

    always @(posedge clk) begin
        if (rst) begin
            pixel_div <= 0; h <= 0; v <= 0;
            visible_delay <= 0; scan_valid <= 0; scan_addr <= 0;
            hsync <= 1; vsync <= 1;
        end else begin
            pixel_div <= pixel_div + 2'd1;
            if (pixel_enable) begin
                if (h == 10'd799) begin
                    h <= 0;
                    v <= v == 10'd524 ? 10'd0 : v + 10'd1;
                end else h <= h + 10'd1;
            end
            // Delay controls alongside the synchronous framebuffer read.
            visible_delay <= visible;
            scan_valid <= pixel_enable && visible;
            scan_addr <= read_addr;
            hsync <= !(h >= 10'd656 && h < 10'd752);
            vsync <= !(v >= 10'd490 && v < 10'd492);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; done <= 0; error <= 0;
            initialized <= 0; target_buffer <= 0; front_buffer <= 0;
            display_enabled <= 0; clear_index <= 0;
            remaining <= 0; in_flight <= 0; active_near <= 32'sd65536;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    error <= 0; target_buffer <= buffer_select;
                    if (cmd == 2'd3 ||
                        ((cmd == 0 || cmd == 1) && display_enabled && buffer_select == front_buffer) ||
                        ((cmd == 1 || cmd == 2) && !initialized[buffer_select]) ||
                        (cmd == 1 && near_q16 <= 0)) begin
                        error <= 1; done <= 1;
                    end else case (cmd)
                        2'd0: begin state <= CLEAR; clear_index <= 0; end
                        2'd1: begin
                            state <= DRAW; remaining <= vertex_count;
                            in_flight <= 0; active_near <= near_q16;
                        end
                        2'd2: state <= PRESENT;
                        default: state <= IDLE;
                    endcase
                end
                CLEAR: if (clear_index == 19'd307199) begin
                    initialized[target_buffer] <= 1; state <= IDLE; done <= 1;
                end else clear_index <= clear_index + 19'd1;
                DRAW: begin
                    if (accept_vertex) remaining <= remaining - 32'd1;
                    case ({accept_vertex, finish_vertex})
                        2'b10: in_flight <= in_flight + 7'd1;
                        2'b01: in_flight <= in_flight - 7'd1;
                        default: in_flight <= in_flight;
                    endcase
                    if (remaining == 0 && in_flight == 0) begin state <= IDLE; done <= 1; end
                end
                PRESENT: if (vblank_start) begin
                    front_buffer <= target_buffer; display_enabled <= 1;
                    state <= IDLE; done <= 1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
