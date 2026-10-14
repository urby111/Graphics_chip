`timescale 1ns / 1ps

module System_Memory #(
    parameter GPU_MODE = 0
) (
    input  wire        clk,
    input  wire [18:0] addr,
    output reg         dout,
    input wire         read_buffer,
    input wire         wr_en,
    input wire [19:0]  wr_addr,
    input wire         wr_data
);
    generate if (GPU_MODE) begin : gpu
        // Red/black demo: one bit per pixel, two 640x480 framebuffers.
        // No reset loop or file initialization: the GPU explicitly clears RAM.
        (* ram_style = "block" *) reg frame_buffer [0:614399];
        wire [19:0] read_index = {1'b0, addr} +
                                (read_buffer ? 20'd307200 : 20'd0);
        always @(posedge clk) begin
            if (wr_en && wr_addr < 20'd614400)
                frame_buffer[wr_addr] <= wr_data;
            dout <= frame_buffer[read_index];
        end
    end else begin : font
    wire unused_write_ports = ^{read_buffer, wr_en, wr_addr, wr_data};
    // 640 * 480 monochrome pixels, packed eight pixels per byte.
    reg [7:0] frame_buffer [0:38399];
    integer i;

    initial begin
        // Keep the unused part of a short input file deterministic and black.
        for (i = 0; i < 38400; i = i + 1) begin
            frame_buffer[i] = 8'h00;
        end
        // This must be the scanline-ordered framebuffer, NOT font_glyphs.hex
        // (which stores eight consecutive rows per character).
        $readmemh("font_aligned.hex", frame_buffer);
    end

    always @(posedge clk) begin
        // Byte address is addr / 8. Within each byte, display the MSB first.
        dout <= frame_buffer[addr[18:3]][3'd7 - addr[2:0]];
    end
    end endgenerate
endmodule
