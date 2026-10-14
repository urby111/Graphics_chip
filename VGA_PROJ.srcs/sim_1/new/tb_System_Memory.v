`timescale 1ns / 1ps

module tb_System_Memory;
    reg clk = 0;
    reg [18:0] addr = 0;
    wire dout;

    System_Memory uut (
        .clk(clk),
        .addr(addr),
        .dout(dout),
        .read_buffer(1'b0), .wr_en(1'b0), .wr_addr(20'b0), .wr_data(1'b0)
    );

    always #5 clk = ~clk;

    initial begin
        #20;
        $display("--- Starting sequential pixel read test ---");
        repeat (16) begin
            @(posedge clk);
            #1;
            $display("Pixel address: %0d | value: %b", addr, dout);
            addr = addr + 1;
        end

        $display("--- Simulation complete ---");
        $finish;
    end
endmodule
