`timescale 1ns/1ps
// Both tile memories have one synchronous read cycle. rv/rl follow that read.
// Lane i is delayed i extra clocks: W[r,k] and X[k,c] meet at k+r+c.
module data_mapper(
    input wire clk,rst,start,
    input wire [7:0] k_count,
    output wire rd_en,
    output wire [7:0] rd_addr,
    input wire [63:0] act_data,weight_data,
    output wire [63:0] activations,weights,
    output wire [7:0] av,wv,al,wl,
    output reg [3:0] act_rd_ic,act_rd_tap
);
    reg feeding,rv,rl;
    reg [7:0] count;
    assign rd_en=feeding;
    assign rd_addr=count;
    always @(posedge clk) begin
        if(rst) begin feeding<=0;count<=0;rv<=0;rl<=0;act_rd_ic<=0;act_rd_tap<=0;end
        else if(start) begin feeding<=1;count<=0;rv<=0;rl<=0;act_rd_ic<=0;act_rd_tap<=0;end
        else begin
            rv<=rd_en; rl<=rd_en && count==k_count-1;
            if(feeding) begin
                if(count==k_count-1) feeding<=0;
                else begin
                    count<=count+1'b1;
                    if(act_rd_tap==8) begin act_rd_tap<=0;act_rd_ic<=act_rd_ic+1'b1;end
                    else act_rd_tap<=act_rd_tap+1'b1;
                end
            end
        end
    end
    genvar lane;
    generate for(lane=0;lane<8;lane=lane+1) begin: skew
        reg [7:0] ad[0:lane],wd[0:lane];
        reg [lane:0] v,l;
        integer j;
        always @(posedge clk) begin
            if(rst || start) begin
                v<=0;l<=0;
                for(j=0;j<=lane;j=j+1) begin ad[j]<=0;wd[j]<=0;end
            end else begin
                ad[0]<=act_data[lane*8+:8];wd[0]<=weight_data[lane*8+:8];
                v[0]<=rv;l[0]<=rl;
                for(j=1;j<=lane;j=j+1) begin
                    ad[j]<=ad[j-1];wd[j]<=wd[j-1];v[j]<=v[j-1];l[j]<=l[j-1];
                end
            end
        end
        assign activations[lane*8+:8]=ad[lane];
        assign weights[lane*8+:8]=wd[lane];
        assign av[lane]=v[lane];assign wv[lane]=v[lane];
        assign al[lane]=l[lane];assign wl[lane]=l[lane];
    end endgenerate
endmodule
