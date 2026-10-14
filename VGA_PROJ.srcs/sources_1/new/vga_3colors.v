`timescale 1ns / 1ps

module vga_3colors (
    input clk,             // 100 MHz clock from Basys 3
    output hsync,          // Horizontal sync
    output vsync,          // Vertical sync
    output reg [3:0] vga_r,// 4-bit Red
    output reg [3:0] vga_g,// 4-bit Green
    output reg [3:0] vga_b // 4-bit Blue
);

    // --- 1. Clock Divider (100 MHz to 25 MHz) ---
    // Standard 640x480 @ 60Hz requires a 25.175 MHz pixel clock.
    // 25 MHz is close enough for almost all monitors to sync.
    reg [1:0] clk_div = 0;
    wire clk_25M;
    
    always @(posedge clk) begin
        clk_div <= clk_div + 1;
    end
    assign clk_25M = clk_div[1]; // Toggles every 4th cycle
    // --- 2. VGA Counters ---
    reg [9:0] h_count = 0; // Horizontal pixel counter
    reg [9:0] v_count = 0; // Vertical line counter

    always @(posedge clk_25M) begin
        // Horizontal counter: 0 to 799
        if (h_count < 799) begin
            h_count <= h_count + 1;
        end else begin
            h_count <= 0;
            // Vertical counter: 0 to 524
            if (v_count < 524) begin
                v_count <= v_count + 1;
            end else begin
                v_count <= 0;
            end
        end
    end

    // --- 3. Sync Signals ---
    // Active low sync pulses based on standard VGA timing
    assign hsync = (h_count >= (640 + 16) && h_count < (640 + 16 + 96)) ? 1'b0 : 1'b1;
    assign vsync = (v_count >= (480 + 10) && v_count < (480 + 10 + 2)) ? 1'b0 : 1'b1;

    // --- 4. Color Output Logic ---
    // Only output colors within the visible 640x480 area
    wire video_on = (h_count < 640 && v_count < 480);

    // The synchronous RAM returns a pixel on the same edge that advances the
    // counters. Request the NEXT position so RGB matches the new counters.
    wire [9:0] next_h = (h_count == 10'd799) ? 10'd0 : h_count + 10'd1;
    wire [9:0] next_v = (h_count == 10'd799) ?
                       ((v_count == 10'd524) ? 10'd0 : v_count + 10'd1) : v_count;
    wire next_video_on = (next_h < 10'd640 && next_v < 10'd480);

    // 19-bit address wire
    wire [18:0] pixel_addr;
    
    // Optimized multiplier for 640 (512 + 128). Extend the counters before
    // shifting so Verilog does not truncate the intermediate values to 10 bits.
    wire [18:0] h_count_extended = {9'b0, next_h};
    wire [18:0] v_count_extended = {9'b0, next_v};
    // Use a valid address during blanking too (RAM only covers 640x480).
    assign pixel_addr = next_video_on ?
                        ((v_count_extended << 9) +
                         (v_count_extended << 7) + h_count_extended) : 19'd0;
    
    wire pixel_data;

    // Instantiate your memory
    System_Memory Ram (
        .clk(clk_25M),                 
        .addr(pixel_addr),
        .dout(pixel_data),
        .read_buffer(1'b0), .wr_en(1'b0), .wr_addr(20'b0), .wr_data(1'b0)
    );
    
    // Color Output Logic
    always @(*) begin
        if (!video_on) begin
            // Blanking time - must be black
            vga_r = 4'b0000;
            vga_g = 4'b0000;
            vga_b = 4'b0000;
        end else begin
            if (pixel_data == 1'b1) begin
                // Turn all colors max for White
                vga_r = 4'b1111; 
                vga_g = 4'b1111; 
                vga_b = 4'b1111; 
            end else begin
                // Turn all colors min for Black
                vga_r = 4'b0000; 
                vga_g = 4'b0000; 
                vga_b = 4'b0000; 
            end
        end
    end
endmodule
