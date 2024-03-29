//+------------------------------------------------------------------+
//|                                               carbon_trader.mq4  |
//|                              Copyright 2023, gmalato@hotmail.com |
//|                                        https://gmalato.github.io |
//+------------------------------------------------------------------+

#property copyright "Copyright © 2023, gmalato@hotmail.com"
#property description "Copy trades between termninals"
#property strict
#property version "1.2"

enum copier_mode {master, slave};
input copier_mode mode = 1; // Mode: use 0 for master, 1 for slave
input double mult = 1.0;    // Slave multiplier
input int slip = 100;       // Slippage in points: use 0 to disable

#define DEBUG true
#define OPEN_ORDERS_LIST_SIZE 512

// global variables
int fileHandle, ticket, type;
double lot, price, sl, tp;
string symbol;

string g_accountNumber = IntegerToString(AccountNumber());
bool g_cleanDeinit = true;
uint g_debugTimerS;
uint g_debugTimerE;
int g_openOrders[OPEN_ORDERS_LIST_SIZE];
int g_ping = 1;
string g_tag = "20230821-1";

//+------------------------------------------------------------------+
//| Initializes the EA; should be replaced by the newer OnInit().    |
//+------------------------------------------------------------------+
void init() {
    Comment(EnumToString(mode), " m:", mult, " s: ", slip, " t: ", g_tag);
    int controlFileHandle;

    // if the EA was started in server mode, make sure no other master is already running
    if (EnumToString(mode) == "master" ) {
        if (FileIsExist("master.ct4", FILE_COMMON)) {
            Print("A master is already running, removing EA");
            g_cleanDeinit = false; // skip master file check during deinit
            ExpertRemove();
        } else {
            controlFileHandle = FileOpen("master.ct4", FILE_WRITE | FILE_CSV | FILE_COMMON);
            if(controlFileHandle == INVALID_HANDLE) {
                Print("Could not write server control file, removing EA");
                ExpertRemove();
            }
            FileWrite(controlFileHandle, AccountInfoInteger(ACCOUNT_LOGIN));
            FileClose(controlFileHandle);
            controlFileHandle = INVALID_HANDLE;
        }
    }

    // If the EA was started in client mode, make sure it's not already attached to any charts
    if (EnumToString(mode) == "slave" ) {
        if (FileIsExist(g_accountNumber + ".ct4", FILE_COMMON)) {
            Print("A client is already running, removing EA");
            g_cleanDeinit = false; // skip slave file check during deinit
            ExpertRemove();
        } else {
            controlFileHandle = FileOpen(g_accountNumber + ".ct4", FILE_WRITE | FILE_CSV | FILE_COMMON);
            if(controlFileHandle == INVALID_HANDLE) {
                Print("Could not write client control file, removing EA");
                ExpertRemove();
            }
            FileWrite(controlFileHandle, g_accountNumber);
            FileClose(controlFileHandle);
            controlFileHandle = INVALID_HANDLE;
        }
    }

    ObjectsDeleteAll();
    EventSetTimer(1);
    return;
}

//+------------------------------------------------------------------+
//| Shuts the EA down                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    Print("Shutting down: ", reason);
    ObjectsDeleteAll();
    EventKillTimer();

    if (EnumToString(mode) == "master" && g_cleanDeinit) {
        if (FileIsExist("master.ct4", FILE_COMMON)) {
            if (FileDelete("master.ct4", FILE_COMMON)) {
                Print("Server control file removed");
            } else {
                Print("Server control file not found");
            }
        }
    }

    if (EnumToString(mode) == "slave" && g_cleanDeinit) {
        if (FileIsExist(g_accountNumber + ".ct4", FILE_COMMON)) {
            if (FileDelete(g_accountNumber + ".ct4", FILE_COMMON)) {
                Print("Client control file removed");
            } else {
                Print("Client control file not found");
            }
        }
    }

    return;
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
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
        // saving information about opened orders
        if(OrdersTotal() == 0) {
            fileHandle = FileOpen("C4F.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
            FileWrite(fileHandle, "");
            FileClose(fileHandle);
        } else {
            fileHandle = FileOpen("C4F.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
            if(fileHandle!=INVALID_HANDLE) {

                if(DEBUG) {
                    g_debugTimerS = GetTickCount();
                }

                for(int i=0; i<OrdersTotal(); i++) {
                    if(!OrderSelect(i, SELECT_BY_POS))
                        break;
                    symbol=OrderSymbol();

                    if(StringSubstr(OrderComment(), 0, 3)!="C4F")
                        FileWrite(fileHandle, OrderTicket(), symbol, OrderType(), OrderOpenPrice(), OrderLots(), OrderStopLoss(), OrderTakeProfit());
                    FileFlush(fileHandle);
                }
                FileClose(fileHandle);

                if (DEBUG) {
                    g_debugTimerE = GetTickCount() - g_debugTimerS;
                    PrintFormat("Writing the orders list took %d ms", g_debugTimerE);
                }

            } else {
                Print("Could not write orders file: ", GetLastError());
            }

        }
    }

    // slave working mode
    if(EnumToString(mode) == "slave") {
        // check for new positions and SL/TP changes
        fileHandle = FileOpen("C4F.csv", FILE_READ|FILE_CSV|FILE_COMMON);
        if(fileHandle != INVALID_HANDLE) {
            if (DEBUG)
                g_debugTimerS = GetTickCount();

            ArrayFill(g_openOrders, 0, OPEN_ORDERS_LIST_SIZE, 0);

            while(!FileIsEnding(fileHandle)) {
                ticket = StrToInteger(FileReadString(fileHandle));
                symbol = FileReadString(fileHandle);
                type = StrToInteger(FileReadString(fileHandle));
                price = StrToDouble(FileReadString(fileHandle));
                lot = StrToDouble(FileReadString(fileHandle))*mult;
                sl = StrToDouble(FileReadString(fileHandle));
                tp = StrToDouble(FileReadString(fileHandle));

                string comment = "C4F" + IntegerToString(ticket);

                for(int i = 0; i < OrdersTotal(); i++) {
                    if(!OrderSelect(i, SELECT_BY_POS))
                        continue;

                    if(OrderComment() != comment)
                        continue;

                    orderAdd(ticket);

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
                    if(type < 2)
                        OpenMarketOrder(ticket, symbol, type, price, lot);

                    if(type > 1)
                        OpenPendingOrder(ticket, symbol, type, price, lot);

                    // TODO: returns beacuse the g_openOrders is not
                    // updated after opening a new order and if we kept
                    // going, the ortder would be closed.
                    // FileClose(fileHandle);
                    // return;

                }
            }
            FileClose(fileHandle);

            if(DEBUG) {
                g_debugTimerE = GetTickCount() - g_debugTimerS;
                PrintFormat("Reading the orders list took %d ms", g_debugTimerE);
            }

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
                if(OrderType() == OP_BUY) {
                    if(!OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_BID), slip))
                        Print("Could not close order ", OrderTicket(), ", error ", GetLastError());
                } else if(OrderType() == OP_SELL) {
                    if(!OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_ASK), slip))
                        Print("Could not close order ", OrderTicket(), ", error ", GetLastError());
                } else if(OrderType() > 1) {
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

    while(g_openOrders[i] != 0) {
        if(g_openOrders[i] == _ticket)
            return(1);
        i++;
    }

    if (DEBUG)
        Print("Ticket ", _ticket, " not found in orders list");

    return(-1);
}

//+------------------------------------------------------------------+
//| Add a new ticket to the list of open orders                      |
//+------------------------------------------------------------------+
bool orderAdd(int _ticket) {
    int _tmp = sizeof(g_openOrders);
    for(int i = 0; i < OPEN_ORDERS_LIST_SIZE; i++) {
        if(g_openOrders[i] == 0) {

            if (DEBUG)
                Print("Ticket ", _ticket, " added to orders list at position ", i);

            g_openOrders[i] = _ticket;
            g_openOrders[i + 1] = 0;
            return true;
        }
    }

    Print("Could not add order ", _ticket, " to the list");
    return false;
}


//+------------------------------------------------------------------+
//|Open market execution orders                                      |
//+------------------------------------------------------------------+
void OpenMarketOrder(int _ticket, string _symbol, int _type, double _price, double _size) {
    double delta = 0;
    double market_price = 0;
    double point_size = 0;

    if(_type == OP_BUY)
        market_price = MarketInfo(_symbol, MODE_ASK);
    else
        market_price = MarketInfo(_symbol, MODE_BID);

    point_size = MarketInfo(_symbol, MODE_POINT);

    // If there's no price and/or point size informatio for the current symbol
    // do not open the order. This usually happens when the symbol is not
    // listed on the terminal's Market Watch window.

    if (market_price == 0 || point_size == 0 ) {
        Print("Missing price and/or point size for symbol ", _symbol);
        return;
    }

    delta = MathAbs(market_price - _price) / point_size;
    if(slip > 0 && delta > slip) {
//        if (g_ping == 1) {
        Print("Order ", _ticket, " for ", _size, " x ", _symbol, " was not copied because of slippage: ", delta);
//        }

        return;
    }

    if(!OrderSend(_symbol, _type, LotNormalize(_size), market_price, slip, 0, 0, "C4F" + IntegerToString(_ticket)))
        Print("Error: ", GetLastError(), " during opening the market order.");
    else
        orderAdd(_ticket);

    return;

}

//+------------------------------------------------------------------+
//|Open pending orders                                               |
//+------------------------------------------------------------------+
void OpenPendingOrder(int _ticket, string symbol_, int type_, double price_, double lot_) {
    if(!OrderSend(symbol_, type_, LotNormalize(lot_), price_, slip, 0, 0, "C4F"+IntegerToString(_ticket)))
        Print("Error: ", GetLastError(), " during setting the pending order.");
    else
        orderAdd(_ticket);
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
