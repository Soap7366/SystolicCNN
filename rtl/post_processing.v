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
    localparam IDLE=0,READ=1,WAIT_RAM=2,ADD=3,MULT=4,ROUND=5,POOL=6,WRITE=7,ABS=8,CLAMP=9,RELU=10;
    reg [3:0] state;reg [5:0] index;
    reg [6:0] x,y;reg [7:0] max_value,pool_value,q;
    reg signed [31:0] acc;
    reg signed [63:0] product;
    reg [63:0] magnitude;
    reg [33:0] rounded;
    wire signed [31:0] selected_bias=biases[index[5:3]*32+:32];
    wire signed [31:0] selected_mult=multipliers[index[5:3]*32+:32];
    assign rd_en=state==READ;assign rd_addr=index;
    assign wr_en=state==WRITE;assign wr_data=pool_value;
    wire [12:0] oc={7'd0,oc_base}+index[5:3];
    reg [12:0] channel_offset,row_offset;
    always @* begin
        case(width)
            64:begin channel_offset=oc<<10;row_offset={7'd0,y[6:1]}<<5;end
            32:begin channel_offset=oc<<8;row_offset={7'd0,y[6:1]}<<4;end
            default:begin channel_offset=oc<<6;row_offset={7'd0,y[6:1]}<<3;end
        endcase
    end
    assign debug_valid=state==MULT;assign debug_acc=acc;assign debug_index=index;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;done<=0;index<=0;x<=0;y<=0;max_value<=0;pool_value<=0;q<=0;acc<=0;product<=0;magnitude<=0;rounded<=0;wr_addr<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start) begin index<=0;x<=tile_x;y<=tile_y;max_value<=0;state<=READ;end
                READ:state<=WAIT_RAM;
                WAIT_RAM:state<=ADD;
                ADD:begin
                    acc<=rd_data+selected_bias;
                    wr_addr<=output_base+channel_offset+row_offset+(x>>1)+index[2];
                    state<=MULT;
                end
                MULT:begin product<=acc*selected_mult;state<=ABS;end
                ABS:begin magnitude<=product[63]?(~product+64'd1):product;state<=ROUND;end
                // Equivalent to (abs(product)+2^30)>>31 without a 64-bit adder.
                ROUND:begin rounded<={1'b0,magnitude[63:31]}+magnitude[30];state<=CLAMP;end
                CLAMP:begin
                    if(rounded>127) q<=product[63]?8'h81:8'h7f;
                    else q<=product[63]?(~rounded[7:0]+8'd1):rounded[7:0];
                    state<=RELU;
                end
                RELU:begin if(q[7]) q<=0;state<=POOL;end
                POOL:begin
                    if(index[1:0]==3) begin
                        pool_value<=q>max_value?q:max_value;max_value<=0;state<=WRITE;
                    end else begin
                        if(q>max_value) max_value<=q;
                        index<=index+1'b1;state<=READ;
                    end
                end
                WRITE:begin
                    if(index==63) begin state<=IDLE;done<=1;end
                    else begin index<=index+1'b1;state<=READ;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
