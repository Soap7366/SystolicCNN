`timescale 1ns/1ps
// Four row banks. In tile-priority scheduling only the six required columns
// (including halo) are resident. The 4x3 sliding window reuses two columns.
module line_buffer(
    input wire clk,wr_en,input wire [1:0] wr_row,input wire [2:0] wr_col,
    input wire [7:0] wr_data,input wire [2:0] rd_col,output wire [31:0] column
);
    reg [7:0] row0[0:5],row1[0:5],row2[0:5],row3[0:5];
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
    output reg valid,output reg [1:0] position,
    output reg [71:0] top_window,bottom_window
);
    reg [7:0] cells[0:11];
    reg [2:0] count;
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
    input wire clk,rst,window_valid,input wire [1:0] position,
    input wire [4:0] ic,input wire [71:0] top_window,bottom_window,
    output wire ready,output reg done,
    output wire wr_en,output wire [7:0] wr_k,
    output reg [2:0] wr_p,output wire [7:0] wr_top,wr_bottom
);
    reg busy;reg [3:0] idx;reg [7:0] base;
    reg [71:0] t,b;
    assign ready=!busy;assign wr_en=busy;assign wr_k=base+idx;
    assign wr_top=t[idx*8+:8];assign wr_bottom=b[idx*8+:8];
    always @(posedge clk) begin
        if(rst) begin busy<=0;done<=0;idx<=0;base<=0;wr_p<=0;t<=0;b<=0;end
        else begin
            done<=0;
            if(window_valid && ready) begin
                t<=top_window;b<=bottom_window;base<=ic*9;idx<=0;
                wr_p<={position[1],1'b0,position[0]};busy<=1;
            end
            if(busy) begin
                if(idx==8) begin busy<=0;done<=1;end
                else idx<=idx+1'b1;
            end
        end
    end
endmodule

module prep_controller(
    input wire clk,rst,start,input wire [6:0] tile_y,tile_x,height,width,
    input wire [4:0] cin,input wire [12:0] input_base,
    output wire feature_en,output reg [12:0] feature_addr,input wire [7:0] feature_data,
    output wire act_wr_en,output wire [7:0] act_wr_k,
    output wire [2:0] act_wr_p,output wire [7:0] act_wr_top,act_wr_bottom,
    output reg done,output wire busy
);
    localparam IDLE=0,REQUEST=1,WAIT_RAM=2,STORE=3,CLEAR_WINDOW=4,SHIFT=5,WAIT_WINDOW=6,ADDRESS=7;
    reg [2:0] state;
    reg [1:0] row;reg [2:0] col,scan_col;
    reg [4:0] ic;
    reg [6:0] x,y;
    reg padding;
    wire signed [9:0] iy=$signed({3'b0,y})+$signed({8'b0,row})-10'sd1;
    wire signed [9:0] ix=$signed({3'b0,x})+$signed({7'b0,col})-10'sd1;
    wire outside=(iy<0 || ix<0 || iy>=$signed({3'b0,height}) || ix>=$signed({3'b0,width}));
    assign feature_en=(state==REQUEST && !padding);
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
    wire [1:0] position;wire [71:0] tw,bw;
    line_buffer rows(.clk(clk),.wr_en(state==STORE),.wr_row(row),.wr_col(col),
        .wr_data(padding?8'd0:feature_data),.rd_col(scan_col),.column(column));
    window_gen_4x3 window(.clk(clk),.rst(rst),.clear(state==CLEAR_WINDOW),
        .step(state==SHIFT),.column(column),.valid(win_valid),.position(position),
        .top_window(tw),.bottom_window(bw));
    window_tile_assembler assembler(.clk(clk),.rst(rst),.window_valid(win_valid),
        .position(position),.ic(ic),.top_window(tw),.bottom_window(bw),
        .ready(asm_ready),.done(asm_done),.wr_en(act_wr_en),.wr_k(act_wr_k),
        .wr_p(act_wr_p),.wr_top(act_wr_top),.wr_bottom(act_wr_bottom));
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;done<=0;row<=0;col<=0;scan_col<=0;ic<=0;x<=0;y<=0;padding<=0;feature_addr<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start) begin x<=tile_x;y<=tile_y;ic<=0;row<=0;col<=0;state<=ADDRESS;end
                ADDRESS:begin
                    padding<=outside;
                    feature_addr<=outside?13'd0:input_base+channel_offset+row_offset+ix[6:0];
                    state<=REQUEST;
                end
                REQUEST:state<=WAIT_RAM;
                WAIT_RAM:state<=STORE;
                STORE:begin
                    if(col==5) begin
                        col<=0;
                        if(row==3) begin scan_col<=0;state<=CLEAR_WINDOW;end
                        else begin row<=row+1'b1;state<=ADDRESS;end
                    end else begin col<=col+1'b1;state<=ADDRESS;end
                end
                CLEAR_WINDOW:state<=SHIFT;
                SHIFT:state<=WAIT_WINDOW;
                WAIT_WINDOW:begin
                    if(scan_col<2 || asm_done) begin
                        if(scan_col==5) begin
                            if(ic==cin-1) begin state<=IDLE;done<=1;end
                            else begin ic<=ic+1'b1;row<=0;col<=0;state<=ADDRESS;end
                        end else begin scan_col<=scan_col+1'b1;state<=SHIFT;end
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
