//+------------------------------------------------------------------+
//|                                               carbon_trader.mq4  |
//|                              Copyright 2023, gmalato@hotmail.com |
//|                                        https://gmalato.github.io |
//+------------------------------------------------------------------+

#property copyright "Copyright © 2023, gmalato@hotmail.com"
#property description "Copy trades between termninals"
#property version "1.2"

#property strict

enum copier_mode {master, slave};

input copier_mode mode = 1; // Mode: use 0 for master, 1 for slave
input double mult = 1.0;    // Slave multiplier
input int slip = 100;       // Slippage in points: use 0 to disable

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
string g_account_number = IntegerToString(AccountNumber());
bool clean_deinit = true;
bool debug = false;
int fileHandle, ticket, type;
double lot, price, sl, tp;
string symbol;
string tag = "20230731-1";
int g_open_orders[500];
int g_ping = 1;

//+------------------------------------------------------------------+
//| Initializes the EA; should be replaced by the newer OnInit().    |
//+------------------------------------------------------------------+
void init() {
    Comment(EnumToString(mode), " m:", mult, " s: ", slip, " t: ", tag);

    // if the EA was started in server mode, make sure no other master is already running
    if (EnumToString(mode) == "master" ) {
        if (FileIsExist("master.ct4", FILE_COMMON)) {
            Print("A master is already running, removing EA");
            clean_deinit = false; // skip master file check during deinit
            ExpertRemove();
        } else {
            fileHandle = FileOpen("master.ct4", FILE_WRITE | FILE_CSV | FILE_COMMON);
            if(fileHandle == INVALID_HANDLE) {
                Print("Could not write server control file, removing EA");
                ExpertRemove();
            }
            FileWrite(fileHandle, AccountInfoInteger(ACCOUNT_LOGIN));
            FileClose(fileHandle);
            fileHandle = -1;
        }
    }

    // If the EA was started in client mode, make sure it's not already attached to any charts
    if (EnumToString(mode) == "slave" ) {
        if (FileIsExist(g_account_number + ".ct4", FILE_COMMON)) {
            Print("A client is already running, removing EA");
            clean_deinit = false; // skip slave file check during deinit
            ExpertRemove();
        } else {
            fileHandle = FileOpen(g_account_number + ".ct4", FILE_WRITE | FILE_CSV | FILE_COMMON);
            if(fileHandle == INVALID_HANDLE) {
                Print("Could not write client control file, removing EA");
                ExpertRemove();
            }
            FileWrite(fileHandle, g_account_number);
            FileClose(fileHandle);
            fileHandle = -1;
        }
    }

    ObjectsDeleteAll();
    EventSetTimer(1);
    return;
}

//+------------------------------------------------------------------+
//| Shuts the EA down; should be replace by the newer OnDeinit().    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    Print("OnDeinit(", reason, ")");
    ObjectsDeleteAll();
    EventKillTimer();

    if (EnumToString(mode) == "master" && clean_deinit) {
        if (FileIsExist("master.ct4", FILE_COMMON)) {
            if (FileDelete("master.ct4", FILE_COMMON)) {
                Print("Server control file removed");
            } else {
                Print("Server control file not found");
            }
        }
    }

    if (EnumToString(mode) == "slave" && clean_deinit) {
        if (FileIsExist(g_account_number + ".ct4", FILE_COMMON)) {
            if (FileDelete(g_account_number + ".ct4", FILE_COMMON)) {
                Print("Client control file removed");
            } else {
                Print("Client controlnot found");
            }
        }
    }

    return;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTimer() {
    if(g_ping == 30) {
        g_ping = 1;
        Print("PING");
    } else {
        g_ping += 1;
    }

    // master working mode
    if(EnumToString(mode)=="master") {
        //--- Saving information about opened deals
        if(OrdersTotal()==0) {
            fileHandle=FileOpen("C4F.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
            FileWrite(fileHandle, "");
            FileClose(fileHandle);
        } else {
            fileHandle=FileOpen("C4F.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);

            if(fileHandle!=INVALID_HANDLE) {
                for(int i=0; i<OrdersTotal(); i++) {
                    if(!OrderSelect(i, SELECT_BY_POS))
                        break;
                    symbol=OrderSymbol();

                    if(StringSubstr(OrderComment(), 0, 3)!="C4F")
                        FileWrite(fileHandle, OrderTicket(), symbol, OrderType(), OrderOpenPrice(), OrderLots(), OrderStopLoss(), OrderTakeProfit());
                    FileFlush(fileHandle);
                }
                FileClose(fileHandle);
            }
        }
    }

    // slave working mode
    if(EnumToString(mode) == "slave") {
        // check for new positions and SL/TP changes
        fileHandle = FileOpen("C4F.csv", FILE_READ|FILE_CSV|FILE_COMMON);

        if(fileHandle != INVALID_HANDLE) {
            int o = 0;
            g_open_orders[o] = 0;

            while(!FileIsEnding(fileHandle)) {
                ticket = StrToInteger(FileReadString(fileHandle));
                symbol = FileReadString(fileHandle);
                type = StrToInteger(FileReadString(fileHandle));
                price = StrToDouble(FileReadString(fileHandle));
                lot = StrToDouble(FileReadString(fileHandle))*mult;
                sl = StrToDouble(FileReadString(fileHandle));
                tp = StrToDouble(FileReadString(fileHandle));

                string
                OrdComm = "C4F" + IntegerToString(ticket);

                for(int i = 0; i < OrdersTotal(); i++) {
                    if(!OrderSelect(i, SELECT_BY_POS))
                        continue;

                    if(OrderComment() != OrdComm)
                        continue;

                    g_open_orders[o] = ticket;
                    g_open_orders[o+1] = 0;
                    o++;

                    if(OrderType() > 1 && OrderOpenPrice() != price) {
                        if(!OrderModify(OrderTicket(), price, 0, 0, 0))
                            Print("Error: ", GetLastError(), " during modification of the order.");
                    }

                    if(tp != OrderTakeProfit() || sl != OrderStopLoss()) {
                        if(!OrderModify(OrderTicket(), OrderOpenPrice(), sl, tp, 0))
                            Print("Error: ", GetLastError(), " during modification of the order.");
                    }
                    break;
                }

                //--- If deal was not opened yet on slave-account, open it.
                if(InList(ticket) == -1 && ticket != 0) {
                    // Removed as of 20230730_1: FileClose(fileHandle);
                    if(type < 2)
                        OpenMarketOrder(ticket, symbol, type, price, lot);
                        
                    if(type > 1)
                        OpenPendingOrder(ticket, symbol, type, price, lot);
                        
                    FileClose(fileHandle);
                    return; // TODO: returns beacuse the g_open_orders is not 
                            // updated after opening a new order and if we kept
                            // going, the ortder would be closed. 
                }
            }
            FileClose(fileHandle);
        } else {
            Print("Could not open orders file: ", GetLastError());
            return;
        }

        // if a position was closed on the master account, close it on the slave
        for(int i = 0; i < OrdersTotal(); i++) {
            if(!OrderSelect(i, SELECT_BY_POS))
                continue;

            if(StringSubstr(OrderComment(), 0, 3) != "C4F")  // TODO: Watch this! :)
                continue;

            if(InList(StrToInteger(StringSubstr(OrderComment(), StringLen("C4F"), 0))) == -1) {
                int ot = OrderTicket();
                if(OrderType() == 0) {
                    if(!OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_BID), slip))
                        Print("Could not close order ", OrderTicket(), ", error ", GetLastError());
                } else if(OrderType() == 1) {
                    if(!OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_ASK), slip))
                        Print("Could not close order ", OrderTicket(), ", error ", GetLastError());
                } else if(OrderType()>1) {
                    if(!OrderDelete(OrderTicket()))
                        Print("Could not close pending order ", OrderTicket(), ", error ", GetLastError());
                }
            }
        }
    }
}


//+------------------------------------------------------------------+
//|Checking list                                                     |
//+------------------------------------------------------------------+
int InList(int _ticket) {
    int i = 0;


    while(g_open_orders[i] != 0) {
        if(g_open_orders[i] == _ticket)
            return(1);
        i++;
    }
    
    return(-1);
}
//+------------------------------------------------------------------+
//|Open market execution orders                                      |
//+------------------------------------------------------------------+
void OpenMarketOrder(int _ticket, string _symbol, int _type, double _price, double _size) {
    double delta;
    double market_info = MarketInfo(_symbol, MODE_POINT);
    double market_price = MarketInfo(_symbol, MODE_BID);

    if(_type == OP_BUY)
        market_price = MarketInfo(_symbol, MODE_ASK);

    if (market_info == 0 ) {
        Print("MarketInfo() for symbol ", _symbol, " returned ", market_info);
        market_info = 0.01;
    }

    delta = MathAbs(market_price - _price) / market_info;
    if(slip > 0 && delta > slip) {
        if (g_ping == 1) {
            Print("Order ", _ticket, " for ", _size, " x ", _symbol, " was not copied because of slippage: ", delta);
        }

        return;
    }

    if(!OrderSend(_symbol, _type, LotNormalize(_size), market_price, slip, 0, 0, "C4F" + IntegerToString(_ticket)))
        Print("Error: ", GetLastError(), " during opening the market order.");

    return;

}

//+------------------------------------------------------------------+
//|Open pending orders                                               |
//+------------------------------------------------------------------+
void OpenPendingOrder(int ticket_, string symbol_, int type_, double price_, double lot_) {
    if(!OrderSend(symbol_, type_, LotNormalize(lot_), price_, slip, 0, 0, "C4F"+IntegerToString(ticket_)))
        Print("Error: ", GetLastError(), " during setting the pending order.");
    return;
}
//+------------------------------------------------------------------+
//|Normalize lot size                                                |
//+------------------------------------------------------------------+
double LotNormalize(double lot_) {
    double minlot=MarketInfo(symbol, MODE_MINLOT);

    if(minlot==0.001)
        return(NormalizeDouble(lot_, 3));
    else if(minlot==0.01)
        return(NormalizeDouble(lot_, 2));
    else if(minlot==0.1)
        return(NormalizeDouble(lot_, 1));

    return(NormalizeDouble(lot_, 0));
}
//+------------------------------------------------------------------+
