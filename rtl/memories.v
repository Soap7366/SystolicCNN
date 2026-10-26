`timescale 1ns/1ps
module feature_bram(
    input wire clk,wr_en,input wire [12:0] wr_addr,input wire [7:0] wr_data,
    input wire rd_en,input wire [12:0] rd_addr,output reg [7:0] rd_data
);
    (* ram_style="block" *) reg [7:0] mem[0:8191];
    // No reset on storage or read output: preserves block RAM inference.
    always @(posedge clk) begin
        if(wr_en) mem[wr_addr]<=wr_data;
        if(rd_en) rd_data<=mem[rd_addr];
    end
endmodule

module parameter_rom #(parameter WIDTH=8,DEPTH=8192,AW=13,FILE="data/weights.hex")(
    input wire clk,en,input wire [AW-1:0] addr,output reg [WIDTH-1:0] data
);
    reg [WIDTH-1:0] mem[0:DEPTH-1];
    initial $readmemh(FILE,mem);
    always @(posedge clk) if(en) data<=mem[addr];
endmodule

module weight_tile_buffer(
    input wire clk,wr_en,input wire [2:0] wr_lane,input wire [7:0] wr_addr,
    input wire [7:0] wr_data,input wire rd_en,input wire [7:0] rd_addr,
    output wire [63:0] rd_data
);
    genvar i;
    generate for(i=0;i<8;i=i+1) begin: banks
        (* ram_style="distributed" *) reg [7:0] mem[0:143];
        reg [7:0] q;
        always @(posedge clk) begin
            if(wr_en && wr_lane==i) mem[wr_addr]<=wr_data;
            if(rd_en) q<=mem[rd_addr];
        end
        assign rd_data[i*8+:8]=q;
    end endgenerate
endmodule

module activation_tile_buffer(
    input wire clk,wr_en,wr_bank,input wire [3:0] wr_ic,
    input wire [3:0] wr_p,input wire [71:0] wr_top,wr_bottom,
    input wire rd_en,rd_bank,input wire [3:0] rd_ic,rd_tap,
    output reg [127:0] rd_data
);
    // Bank by kernel tap AND spatial lane; the remaining depth is Cin<=16.
    // A window pair writes 18 independent banks in one cycle. Logical data
    // order is still X[k=ic*9+tap][lane], with the same one-cycle read interface.
    wire [1151:0] taps0,taps1;
    genvar tap,lane;
    generate for(tap=0;tap<9;tap=tap+1) begin: taps
        for(lane=0;lane<16;lane=lane+1) begin: lanes
            (* ram_style="distributed" *) reg [7:0] bank0[0:15];
            (* ram_style="distributed" *) reg [7:0] bank1[0:15];
            wire we=wr_en && (wr_p==lane || wr_p+4'd2==lane);
            wire [7:0] d=(wr_p==lane)?wr_top[tap*8+:8]:wr_bottom[tap*8+:8];
            always @(posedge clk) begin
                if(we && !wr_bank) bank0[wr_ic]<=d;
                if(we && wr_bank) bank1[wr_ic]<=d;
            end
            assign taps0[tap*128+lane*8+:8]=bank0[rd_ic];
            assign taps1[tap*128+lane*8+:8]=bank1[rd_ic];
        end
    end endgenerate
    always @(posedge clk) if(rd_en)
        rd_data<=rd_bank?taps1[rd_tap*128+:128]:taps0[rd_tap*128+:128];
endmodule

module output_tile_buffer(
    input wire clk,wr_en,wr_bank,input wire [4095:0] wr_data,
    input wire rd_en,rd_bank,input wire [4:0] rd_addr,
    output wire [127:0] rd_data
);
    // Four lanes per pool group, 32 words per lane per snapshot bank.
    genvar lane,group_index;
    generate for(lane=0;lane<4;lane=lane+1) begin: lanes
        reg [1023:0] bank0,bank1;
        reg [31:0] q;
        for(group_index=0;group_index<32;group_index=group_index+1) begin: groups
            always @(posedge clk) if(wr_en) begin
                if(wr_bank) bank1[group_index*32+:32]<=wr_data[(group_index*4+lane)*32+:32];
                else bank0[group_index*32+:32]<=wr_data[(group_index*4+lane)*32+:32];
            end
        end
        always @(posedge clk) if(rd_en)
            q<=rd_bank?bank1[rd_addr*32+:32]:bank0[rd_addr*32+:32];
        assign rd_data[lane*32+:32]=q;
    end endgenerate
endmodule
