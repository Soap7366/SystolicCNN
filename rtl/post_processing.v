`timescale 1ns/1ps
module post_processing(
    input wire clk,rst,start,input wire [6:0] tile_y,tile_x,height,width,
    input wire [5:0] oc_base,input wire [12:0] output_base,
    input wire [255:0] biases,multipliers,
    output wire rd_en,output wire [5:0] rd_addr,input wire signed [31:0] rd_data,
    output wire wr_en,output reg [12:0] wr_addr,output wire [7:0] wr_data,
    output reg done,
    output wire debug_valid,output wire signed [31:0] debug_acc,output wire [5:0] debug_index
);
    // One INT32 read request per cycle. Each valid token carries its channel,
    // spatial index, parameter values and final write address through the pipe.
    reg active,feeding;reg [5:0] index;
    reg [6:0] x,y;
    reg read_valid,acc_valid,prod_valid,abs_valid,round_valid,quant_valid,relu_valid,write_valid;
    reg [5:0] read_index,acc_index,prod_index,abs_index,round_index,quant_index,relu_index;
    reg [12:0] read_address,acc_address,prod_address,abs_address,round_address,quant_address,relu_address;
    reg signed [31:0] read_bias,read_mult,acc_mult,acc;
    reg signed [63:0] product;
    reg [63:0] magnitude;
    reg [33:0] rounded;
    reg abs_negative,round_negative;
    reg [7:0] q,relu_q,max_value,pool_value;
    reg write_last;
    wire signed [31:0] selected_bias=biases[index[5:3]*32+:32];
    wire signed [31:0] selected_mult=multipliers[index[5:3]*32+:32];
    assign rd_en=feeding && !rst;assign rd_addr=index;
    assign wr_en=write_valid && !rst;assign wr_data=pool_value;
    wire [12:0] oc={7'd0,oc_base}+index[5:3];
    reg [12:0] channel_offset,row_offset;
    always @* begin
        case(width)
            64:begin channel_offset=oc<<10;row_offset={7'd0,y[6:1]}<<5;end
            32:begin channel_offset=oc<<8;row_offset={7'd0,y[6:1]}<<4;end
            default:begin channel_offset=oc<<6;row_offset={7'd0,y[6:1]}<<3;end
        endcase
    end
    assign debug_valid=acc_valid;assign debug_acc=acc;assign debug_index=acc_index;
    always @(posedge clk) begin
        if(rst) begin
            active<=0;feeding<=0;done<=0;index<=0;x<=0;y<=0;
            read_valid<=0;acc_valid<=0;prod_valid<=0;abs_valid<=0;round_valid<=0;quant_valid<=0;relu_valid<=0;write_valid<=0;
            read_index<=0;acc_index<=0;prod_index<=0;abs_index<=0;round_index<=0;quant_index<=0;relu_index<=0;
            read_address<=0;acc_address<=0;prod_address<=0;abs_address<=0;round_address<=0;quant_address<=0;relu_address<=0;
            read_bias<=0;read_mult<=0;acc_mult<=0;acc<=0;product<=0;magnitude<=0;rounded<=0;
            abs_negative<=0;round_negative<=0;q<=0;relu_q<=0;max_value<=0;pool_value<=0;wr_addr<=0;write_last<=0;
        end
        else begin
            done<=0;
            read_valid<=rd_en;
            acc_valid<=read_valid;prod_valid<=acc_valid;abs_valid<=prod_valid;
            round_valid<=abs_valid;quant_valid<=round_valid;relu_valid<=quant_valid;
            write_valid<=0;
            if(rd_en) begin
                // Output Tile Buffer produces rd_data after this same edge.
                read_index<=index;read_bias<=selected_bias;read_mult<=selected_mult;
                read_address<=output_base+channel_offset+row_offset+(x>>1)+index[2];
                if(index==63) feeding<=0;
                else index<=index+1'b1;
            end
            if(read_valid) begin
                acc<=rd_data+read_bias;acc_mult<=read_mult;
                acc_index<=read_index;acc_address<=read_address;
            end
            if(acc_valid) begin
                product<=acc*acc_mult;prod_index<=acc_index;prod_address<=acc_address;
            end
            if(prod_valid) begin
                magnitude<=product[63]?(~product+64'd1):product;abs_negative<=product[63];
                abs_index<=prod_index;abs_address<=prod_address;
            end
            if(abs_valid) begin
                // Exact half-away-from-zero: (abs(product)+2^30)>>31.
                rounded<={1'b0,magnitude[63:31]}+magnitude[30];round_negative<=abs_negative;
                round_index<=abs_index;round_address<=abs_address;
            end
            if(round_valid) begin
                if(rounded>127) q<=round_negative?8'h81:8'h7f;
                else q<=round_negative?(~rounded[7:0]+8'd1):rounded[7:0];
                quant_index<=round_index;quant_address<=round_address;
            end
            if(quant_valid) begin
                relu_q<=q[7]?8'd0:q;relu_index<=quant_index;relu_address<=quant_address;
            end
            if(relu_valid) begin
                if(relu_index[1:0]==0) max_value<=relu_q;
                else if(relu_index[1:0]==3) begin
                    pool_value<=relu_q>max_value?relu_q:max_value;max_value<=0;
                    wr_addr<=relu_address;write_valid<=1;write_last<=relu_index==63;
                end else if(relu_q>max_value) max_value<=relu_q;
            end
            // The external Feature BRAM commits this final valid write now.
            // Release the Output Tile bank only after that edge, never earlier.
            if(write_valid && write_last) begin active<=0;done<=1;end
            if(start && !active) begin
                active<=1;feeding<=1;index<=0;x<=tile_x;y<=tile_y;max_value<=0;write_last<=0;
                read_valid<=0;acc_valid<=0;prod_valid<=0;abs_valid<=0;
                round_valid<=0;quant_valid<=0;relu_valid<=0;write_valid<=0;
            end
        end
    end
endmodule
