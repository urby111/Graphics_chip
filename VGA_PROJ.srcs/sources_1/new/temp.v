`timescale 1ns / 1ps



module temp (

    input  wire         clk,

    input  wire [18:0]  addr, // Still 19 bits: asks for pixel 0 up to 307199

    output reg  [0:0]   dout  // Still spits out exactly 1 bit

);



    // 1. Reorganized Memory: 38,400 bytes (8 bits wide)

    // 38,400 bytes * 8 bits = 307,200 total bits

    reg [7:0] frame_buffer [0:38399];

    

    integer i;



    initial begin

        // Fill the memory with 0s (Black background)

        for (i = 0; i < 38400; i = i + 1) begin

            frame_buffer[i] = 8'h00; 

        end



        // Load the hex file.

        // Because the array is 8 bits wide, '4D' fits perfectly into index 0, '5A' into index 1, etc.

        $readmemh("C:/Users/troyv/Documents/font_alligned.hex", frame_buffer);

    end



    // Standard synchronous BRAM read block

    always @(posedge clk) begin

        // THE HARDWARE TRICK:

        // addr[18:3] divides the incoming address by 8 to find the right byte.

        // ~addr[2:0] looks at the remainder to pick out the specific bit (MSB first).

        dout <= frame_buffer[addr[18:3]][~addr[2:0]];



    end



endmodule
