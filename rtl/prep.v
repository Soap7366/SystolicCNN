`timescale 1ns/1ps
// Four row banks. In tile-priority scheduling only the ten required columns
// (including halo) are resident. The 4x3 sliding window reuses two columns.
module line_buffer(
    input wire clk,wr_en,input wire [1:0] wr_row,input wire [3:0] wr_col,
    input wire [7:0] wr_data,input wire [3:0] rd_col,output wire [31:0] column
);
    reg [7:0] row0[0:9],row1[0:9],row2[0:9],row3[0:9];
    always @(posedge clk) if(wr_en) begin
        case(wr_row)
            0:row0[wr_col]<=wr_data;1:row1[wr_col]<=wr_data;
            2:row2[wr_col]<=wr_data;3:row3[wr_col]<=wr_data;
        endcase
    end
    assign column={row3[rd_col],row2[rd_col],row1[rd_col],row0[rd_col]};
endmodule

module window_gen_4x3(
    input wire clk,rst,clear,step,input wire [31:0] column,
    output reg valid,output reg [2:0] position,
    output reg [71:0] top_window,bottom_window
);
    reg [7:0] cells[0:11];
    reg [3:0] count;
    integer r,c;
    always @(posedge clk) begin
        if(rst || clear) begin
            count<=0;valid<=0;position<=0;top_window<=0;bottom_window<=0;
            for(r=0;r<12;r=r+1) cells[r]<=0;
        end else begin
            valid<=0;
            if(step) begin
                for(r=0;r<4;r=r+1) begin
                    cells[r*3]<=cells[r*3+1];
                    cells[r*3+1]<=cells[r*3+2];
                    cells[r*3+2]<=column[r*8+:8];
                end
                count<=count+1'b1;
                if(count>=2) begin
                    valid<=1;position<=count-2;
                    for(r=0;r<3;r=r+1) begin
                        top_window[(r*3)*8+:8]<=cells[r*3+1];
                        top_window[(r*3+1)*8+:8]<=cells[r*3+2];
                        top_window[(r*3+2)*8+:8]<=column[r*8+:8];
                        bottom_window[(r*3)*8+:8]<=cells[(r+1)*3+1];
                        bottom_window[(r*3+1)*8+:8]<=cells[(r+1)*3+2];
                        bottom_window[(r*3+2)*8+:8]<=column[(r+1)*8+:8];
                    end
                end
            end
        end
    end
endmodule

module window_tile_assembler(
    input wire clk,rst,window_valid,input wire [2:0] position,
    input wire [4:0] ic,input wire [71:0] top_window,bottom_window,
    output wire ready,output wire done,
    output wire wr_en,output wire [3:0] wr_ic,
    output wire [3:0] wr_p,output wire [71:0] wr_top,wr_bottom
);
    // Nine tap banks accept the entire pair of 3x3 windows on one edge.
    // position 0..7 maps to spatial pairs 0/2,1/3,...,12/14,13/15.
    assign ready=!rst;
    assign wr_en=window_valid && !rst;
    assign done=wr_en && position==7;
    assign wr_ic=ic[3:0];
    assign wr_p={position[2:1],1'b0,position[0]};
    assign wr_top=top_window;assign wr_bottom=bottom_window;
endmodule

module prep_controller(
    input wire clk,rst,start,input wire [6:0] tile_y,tile_x,height,width,
    input wire [4:0] cin,input wire [12:0] input_base,
    output wire feature_en,output reg [12:0] feature_addr,input wire [7:0] feature_data,
    output wire act_wr_en,output wire [3:0] act_wr_ic,
    output wire [3:0] act_wr_p,output wire [71:0] act_wr_top,act_wr_bottom,
    output reg done,output wire busy
);
    localparam IDLE=0,STREAM=1,DRAIN=2,CLEAR_WINDOW=3,SHIFT=4,FLUSH=5;
    reg [2:0] state;
    reg [1:0] row;reg [3:0] col,scan_col;
    reg [4:0] ic;
    reg [6:0] x,y;
    // Address stage -> synchronous BRAM request -> tagged return/write stage.
    // Padding is a valid pipeline token even though it issues no RAM request.
    reg req_valid,req_padding,ret_valid,ret_padding;
    reg [1:0] req_row,ret_row;
    reg [3:0] req_col,ret_col;
    wire signed [9:0] iy=$signed({3'b0,y})+$signed({8'b0,row})-10'sd1;
    wire signed [9:0] ix=$signed({3'b0,x})+$signed({6'b0,col})-10'sd1;
    wire outside=(iy<0 || ix<0 || iy>=$signed({3'b0,height}) || ix>=$signed({3'b0,width}));
    assign feature_en=req_valid && !req_padding && !rst;
    reg [12:0] channel_offset,row_offset;
    always @* begin
        case(width)
            64:begin channel_offset={8'd0,ic}<<12;row_offset={3'd0,iy}<<6;end
            32:begin channel_offset={8'd0,ic}<<10;row_offset={3'd0,iy}<<5;end
            default:begin channel_offset={8'd0,ic}<<8;row_offset={3'd0,iy}<<4;end
        endcase
    end
    assign busy=state!=IDLE;
    wire [31:0] column;
    wire win_valid,asm_ready,asm_done;
    wire [2:0] position;wire [71:0] tw,bw;
    line_buffer rows(.clk(clk),.wr_en(ret_valid && !rst),.wr_row(ret_row),.wr_col(ret_col),
        .wr_data(ret_padding?8'd0:feature_data),.rd_col(scan_col),.column(column));
    window_gen_4x3 window(.clk(clk),.rst(rst),.clear(state==CLEAR_WINDOW),
        .step(state==SHIFT),.column(column),.valid(win_valid),.position(position),
        .top_window(tw),.bottom_window(bw));
    window_tile_assembler assembler(.clk(clk),.rst(rst),.window_valid(win_valid),
        .position(position),.ic(ic),.top_window(tw),.bottom_window(bw),
        .ready(asm_ready),.done(asm_done),.wr_en(act_wr_en),.wr_ic(act_wr_ic),
        .wr_p(act_wr_p),.wr_top(act_wr_top),.wr_bottom(act_wr_bottom));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done<=0;row<=0;col<=0;scan_col<=0;ic<=0;x<=0;y<=0;feature_addr<=0;
            req_valid<=0;req_padding<=0;req_row<=0;req_col<=0;
            ret_valid<=0;ret_padding<=0;ret_row<=0;ret_col<=0;
        end
        else begin
            done<=0;
            req_valid<=0;
            ret_valid<=req_valid;ret_padding<=req_padding;ret_row<=req_row;ret_col<=req_col;
            case(state)
                IDLE:if(start) begin x<=tile_x;y<=tile_y;ic<=0;row<=0;col<=0;state<=STREAM;end
                STREAM:begin
                    req_valid<=1;req_padding<=outside;req_row<=row;req_col<=col;
                    feature_addr<=outside?13'd0:input_base+channel_offset+row_offset+ix[6:0];
                    if(col==9) begin
                        col<=0;
                        if(row==3) state<=DRAIN;
                        else row<=row+1'b1;
                    end else col<=col+1'b1;
                end
                DRAIN:if(ret_valid && ret_row==3 && ret_col==9) begin scan_col<=0;state<=CLEAR_WINDOW;end
                CLEAR_WINDOW:state<=SHIFT;
                SHIFT:begin
                    if(scan_col==9) state<=FLUSH;
                    else scan_col<=scan_col+1'b1;
                end
                // The final window is committed by Activation Buffer on this edge.
                // Keep ic/bank unchanged until that write, then advance the channel.
                FLUSH:if(asm_done) begin
                    if(ic==cin-1) begin state<=IDLE;done<=1;end
                    else begin ic<=ic+1'b1;row<=0;col<=0;state<=STREAM;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
