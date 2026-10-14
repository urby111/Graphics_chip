`timescale 1ns / 1ps

module temp_tb;

    // --- 1. Testbench Signals ---
    reg         clk;
    reg  [18:0] addr;
    wire [0:0]  dout;

    // --- 2. Instantiate the Unit Under Test (UUT) ---
    temp uut (
        .clk(clk),
        .addr(addr),
        .dout(dout)
    );

    // --- 3. Clock Generation (50 MHz / 20ns period) ---
    always begin
        #10 clk = ~clk;
    end

    // --- 4. Stimulus Block ---
    initial begin
        // Initialize Inputs
        clk = 0;
        addr = 19'd0;

        // Wait 100ns for global reset / initialization stability
        #100;
        
        // --- Test Scenario 1: Read the first 16 pixels sequentially ---
        $display("--- Starting Sequential Pixel Read Test ---");
        repeat (16) begin
            @(posedge clk);
            #1; // Small delay after clock edge to mimic hardware settling
            $display("Time: %0t ns | Addr: %d | dout: %b", $time, addr, dout);
            addr = addr + 1;
        end

        // --- Test Scenario 2: Jump to a completely different byte boundary ---
        // For example, checking pixel address 640 (Start of row 8 in your mapping)
        @(posedge clk);
        addr = 19'd640;
        
        repeat (8) begin
            @(posedge clk);
            #1;
            $display("Time: %0t ns | Addr: %d | dout: %b", $time, addr, dout);
            addr = addr + 1;
        end

        // --- Test Scenario 3: Jump near the end of the 307,200 bit boundary ---
        @(posedge clk);
        addr = 19'd307190;
        
        repeat (10) begin
            @(posedge clk);
            #1;
            $display("Time: %0t ns | Addr: %d | dout: %b", $time, addr, dout);
            addr = addr + 1;
        end

        // Finish the simulation
        #100;
        $display("--- Simulation Finished ---");
        $finish;
    end
      
endmodule
