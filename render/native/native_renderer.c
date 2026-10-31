#include <tcl.h>
#include <tk.h>
#include <X11/Xlib.h>
#include <stdlib.h>
#include <string.h>

typedef struct NativeCell {
    char *text;
    char *foreground;
    char *background;
    int width;
    int bold;
    int italic;
    int underline;
} NativeCell;

typedef struct ColorEntry {
    char *name;
    XColor *color;
    struct ColorEntry *next;
} ColorEntry;

typedef struct NativeWidget {
    Tcl_Interp *interp;
    Tk_Window tkwin;
    Display *display;
    Tcl_Command command;
    Tcl_Obj *screen;
    Tk_Font fonts[4];
    XColor *foreground;
    XColor *background;
    GC gc;
    GC invertGc;
    ColorEntry *colors;
    int colorCount;
    NativeCell *cells;
    int cellCount;
    int rows;
    int cols;
    int cellWidth;
    int cellHeight;
    int fontAscent[4];
    int widthRequest;
    int heightRequest;
    int cursorRow;
    int cursorCol;
    int cursorVisible;
    int cursorBlinkVisible;
    int cursorDirty;
    int cursorShape;
    int selectionActive;
    int selectionStart;
    int selectionEnd;
    int fullRedraws;
    int dirtyRenders;
    int renderedRows;
    int renderedStyleRuns;
    int buildUs;
    int drawUs;
    int maxRowUs;
} NativeWidget;

static char *
CopyString(const char *source)
{
    size_t length = strlen(source);
    char *copy = (char *)ckalloc(length + 1);
    memcpy(copy, source, length + 1);
    return copy;
}

static long
ElapsedMicroseconds(const Tcl_Time *start, const Tcl_Time *end)
{
    return (end->sec - start->sec) * 1000000L +
        end->usec - start->usec;
}

static int
CallScreen(NativeWidget *widget, int objc, Tcl_Obj *const objv[])
{
    Tcl_Obj **callv = (Tcl_Obj **)ckalloc(sizeof(Tcl_Obj *) * (objc + 1));
    int i;
    int result;

    callv[0] = widget->screen;
    for (i = 0; i < objc; ++i) {
        callv[i + 1] = objv[i];
    }

    result = Tcl_EvalObjv(widget->interp, objc + 1, callv, TCL_EVAL_DIRECT);
    ckfree((char *)callv);
    return result;
}

static int
GetScreenDimensions(NativeWidget *widget)
{
    Tcl_Obj *method = Tcl_NewStringObj("dimensions", -1);
    Tcl_Obj *result;
    Tcl_Obj **items;
    int count;

    Tcl_IncrRefCount(method);
    if (CallScreen(widget, 1, &method) != TCL_OK) {
        Tcl_DecrRefCount(method);
        return TCL_ERROR;
    }
    Tcl_DecrRefCount(method);

    result = Tcl_GetObjResult(widget->interp);
    if (Tcl_ListObjGetElements(widget->interp, result, &count, &items) != TCL_OK ||
        count != 2 ||
        Tcl_GetIntFromObj(widget->interp, items[0], &widget->rows) != TCL_OK ||
        Tcl_GetIntFromObj(widget->interp, items[1], &widget->cols) != TCL_OK ||
        widget->rows < 1 || widget->cols < 1) {
        Tcl_SetObjResult(widget->interp,
            Tcl_NewStringObj("Screen dimensions must be positive integers", -1));
        return TCL_ERROR;
    }
    return TCL_OK;
}

static void
FreeCells(NativeWidget *widget)
{
    int i;
    int count = widget->cellCount;

    if (widget->cells == NULL) {
        return;
    }
    for (i = 0; i < count; ++i) {
        if (widget->cells[i].text != NULL) {
            ckfree(widget->cells[i].text);
        }
        if (widget->cells[i].foreground != NULL) {
            ckfree(widget->cells[i].foreground);
        }
        if (widget->cells[i].background != NULL) {
            ckfree(widget->cells[i].background);
        }
    }
    ckfree((char *)widget->cells);
    widget->cells = NULL;
    widget->cellCount = 0;
}

static void
FreeColors(NativeWidget *widget)
{
    ColorEntry *entry = widget->colors;

    while (entry != NULL) {
        ColorEntry *next = entry->next;
        Tk_FreeColor(entry->color);
        ckfree(entry->name);
        ckfree((char *)entry);
        entry = next;
    }
    widget->colors = NULL;
    widget->colorCount = 0;
}

static XColor *
GetColor(NativeWidget *widget, const char *name)
{
    ColorEntry *entry;

    for (entry = widget->colors; entry != NULL; entry = entry->next) {
        if (strcmp(entry->name, name) == 0) {
            return entry->color;
        }
    }

    if (widget->colorCount >= 4096) {
        FreeColors(widget);
    }

    entry = (ColorEntry *)ckalloc(sizeof(ColorEntry));
    entry->name = CopyString(name);
    entry->color = Tk_GetColor(widget->interp, widget->tkwin,
        Tk_GetUid(name));
    if (entry->color == NULL) {
        ckfree(entry->name);
        ckfree((char *)entry);
        return NULL;
    }
    entry->next = widget->colors;
    widget->colors = entry;
    ++widget->colorCount;
    return entry->color;
}

static XColor *
GetCellColor(NativeWidget *widget, const char *name, XColor *defaultColor)
{
    return strcmp(name, "default") == 0
        ? defaultColor : GetColor(widget, name);
}

static int
DictString(Tcl_Interp *interp, Tcl_Obj *dict, const char *key,
    const char **value)
{
    Tcl_Obj *obj;
    Tcl_Obj *keyObj = Tcl_NewStringObj(key, -1);
    int result;

    Tcl_IncrRefCount(keyObj);
    result = Tcl_DictObjGet(interp, dict, keyObj, &obj);
    Tcl_DecrRefCount(keyObj);
    if (result != TCL_OK || obj == NULL) {
        Tcl_SetObjResult(interp,
            Tcl_ObjPrintf("screen cell is missing \"%s\"", key));
        return TCL_ERROR;
    }
    *value = Tcl_GetString(obj);
    return TCL_OK;
}

static int
DictInt(Tcl_Interp *interp, Tcl_Obj *dict, const char *key, int *value)
{
    Tcl_Obj *obj;
    Tcl_Obj *keyObj = Tcl_NewStringObj(key, -1);
    int result;

    Tcl_IncrRefCount(keyObj);
    result = Tcl_DictObjGet(interp, dict, keyObj, &obj);
    Tcl_DecrRefCount(keyObj);
    if (result != TCL_OK || obj == NULL ||
        Tcl_GetIntFromObj(interp, obj, value) != TCL_OK) {
        Tcl_SetObjResult(interp,
            Tcl_ObjPrintf("screen cell has invalid \"%s\"", key));
        return TCL_ERROR;
    }
    return TCL_OK;
}

static int
RefreshRow(NativeWidget *widget, int row)
{
    Tcl_Obj *method = Tcl_NewStringObj("rowCells", -1);
    Tcl_Obj *rowObj = Tcl_NewIntObj(row);
    Tcl_Obj **cells;
    int count;
    int col;
    Tcl_Time start;
    Tcl_Time end;

    Tcl_IncrRefCount(method);
    Tcl_IncrRefCount(rowObj);
    {
        Tcl_Obj *args[2] = {method, rowObj};
        if (CallScreen(widget, 2, args) != TCL_OK) {
            Tcl_DecrRefCount(method);
            Tcl_DecrRefCount(rowObj);
            return TCL_ERROR;
        }
    }
    Tcl_DecrRefCount(method);
    Tcl_DecrRefCount(rowObj);

    if (Tcl_ListObjGetElements(widget->interp, Tcl_GetObjResult(widget->interp),
            &count, &cells) != TCL_OK || count != widget->cols) {
        Tcl_SetObjResult(widget->interp,
            Tcl_NewStringObj("Screen row has an unexpected number of cells", -1));
        return TCL_ERROR;
    }

    Tcl_GetTime(&start);
    for (col = 0; col < widget->cols; ++col) {
        NativeCell *cell = &widget->cells[row * widget->cols + col];
        const char *text;
        const char *foreground;
        const char *background;
        int width;
        int inverse;
        int bold;
        int italic;
        int underline;

        if (DictString(widget->interp, cells[col], "text", &text) != TCL_OK ||
            DictString(widget->interp, cells[col], "fg", &foreground) != TCL_OK ||
            DictString(widget->interp, cells[col], "bg", &background) != TCL_OK ||
            DictInt(widget->interp, cells[col], "width", &width) != TCL_OK ||
            DictInt(widget->interp, cells[col], "inverse", &inverse) != TCL_OK ||
            DictInt(widget->interp, cells[col], "bold", &bold) != TCL_OK ||
            DictInt(widget->interp, cells[col], "italic", &italic) != TCL_OK ||
            DictInt(widget->interp, cells[col], "underline", &underline) != TCL_OK) {
            return TCL_ERROR;
        }

        if (cell->text != NULL) ckfree(cell->text);
        if (cell->foreground != NULL) ckfree(cell->foreground);
        if (cell->background != NULL) ckfree(cell->background);

        cell->text = CopyString(text);
        cell->width = width;
        cell->bold = bold;
        cell->italic = italic;
        cell->underline = underline;
        if (inverse) {
            cell->foreground = CopyString(background);
            cell->background = CopyString(foreground);
        } else {
            cell->foreground = CopyString(foreground);
            cell->background = CopyString(background);
        }
    }
    Tcl_GetTime(&end);
    widget->buildUs += (int)ElapsedMicroseconds(&start, &end);
    {
        int col;
        const char *lastForeground = NULL;
        const char *lastBackground = NULL;
        int lastUnderline = -1;
        int lastBold = -1;
        int lastItalic = -1;
        int runs = 0;
        for (col = 0; col < widget->cols; ++col) {
            NativeCell *cell = &widget->cells[row * widget->cols + col];
            if (cell->width == 0) continue;
            if (lastForeground == NULL ||
                strcmp(lastForeground, cell->foreground) != 0 ||
                strcmp(lastBackground, cell->background) != 0 ||
                lastUnderline != cell->underline ||
                lastBold != cell->bold || lastItalic != cell->italic) {
                ++runs;
            }
            lastForeground = cell->foreground;
            lastBackground = cell->background;
            lastUnderline = cell->underline;
            lastBold = cell->bold;
            lastItalic = cell->italic;
        }
        ++widget->renderedRows;
        widget->renderedStyleRuns += runs;
    }
    return TCL_OK;
}

static int
RefreshCursor(NativeWidget *widget)
{
    Tcl_Obj *method = Tcl_NewStringObj("cursor", -1);
    Tcl_Obj *result;
    Tcl_Obj **items;
    int count;
    Tcl_Obj *args[1];

    args[0] = method;
    Tcl_IncrRefCount(method);
    if (CallScreen(widget, 1, args) != TCL_OK) {
        Tcl_DecrRefCount(method);
        return TCL_ERROR;
    }
    Tcl_DecrRefCount(method);
    result = Tcl_GetObjResult(widget->interp);
    if (Tcl_ListObjGetElements(widget->interp, result, &count, &items) != TCL_OK ||
        count != 2 ||
        Tcl_GetIntFromObj(widget->interp, items[0], &widget->cursorRow) != TCL_OK ||
        Tcl_GetIntFromObj(widget->interp, items[1], &widget->cursorCol) != TCL_OK) {
        return TCL_ERROR;
    }

    method = Tcl_NewStringObj("cursorVisible", -1);
    Tcl_IncrRefCount(method);
    args[0] = method;
    if (CallScreen(widget, 1, args) != TCL_OK ||
        Tcl_GetBooleanFromObj(widget->interp, Tcl_GetObjResult(widget->interp),
            &widget->cursorVisible) != TCL_OK) {
        Tcl_DecrRefCount(method);
        return TCL_ERROR;
    }
    Tcl_DecrRefCount(method);

    method = Tcl_NewStringObj("cursorShape", -1);
    Tcl_IncrRefCount(method);
    args[0] = method;
    if (CallScreen(widget, 1, args) != TCL_OK) {
        Tcl_DecrRefCount(method);
        return TCL_ERROR;
    }
    {
        const char *shape = Tcl_GetString(Tcl_GetObjResult(widget->interp));
        widget->cursorShape = strcmp(shape, "underline") == 0 ? 1 :
            (strcmp(shape, "bar") == 0 ? 2 : 0);
    }
    Tcl_DecrRefCount(method);
    return TCL_OK;
}

static int
ConsumeDirty(NativeWidget *widget, int *dirtyCountPtr,
    unsigned char *dirtyRows)
{
    Tcl_Obj *method = Tcl_NewStringObj("consumeDirty", -1);
    Tcl_Obj *args[1];
    Tcl_Obj *changes;
    Tcl_Obj *rowsObj;
    Tcl_Obj *cursorObj;
    Tcl_DictSearch search;
    Tcl_Obj *key;
    Tcl_Obj *value;
    int done;
    int dirtyCount = 0;

    args[0] = method;
    Tcl_IncrRefCount(method);
    if (CallScreen(widget, 1, args) != TCL_OK) {
        Tcl_DecrRefCount(method);
        return TCL_ERROR;
    }
    Tcl_DecrRefCount(method);
    changes = Tcl_GetObjResult(widget->interp);

    if (Tcl_DictObjGet(widget->interp, changes,
            Tcl_NewStringObj("rows", -1), &rowsObj) != TCL_OK ||
        rowsObj == NULL) {
        Tcl_SetObjResult(widget->interp,
            Tcl_NewStringObj("Screen dirty state has no rows dictionary", -1));
        return TCL_ERROR;
    }
    if (Tcl_DictObjGet(widget->interp, changes,
            Tcl_NewStringObj("cursor", -1), &cursorObj) != TCL_OK ||
        cursorObj == NULL ||
        Tcl_GetBooleanFromObj(widget->interp, cursorObj,
            &widget->cursorDirty) != TCL_OK) {
        Tcl_SetObjResult(widget->interp,
            Tcl_NewStringObj("Screen dirty state has no cursor flag", -1));
        return TCL_ERROR;
    }

    if (Tcl_DictObjFirst(widget->interp, rowsObj, &search, &key, &value,
            &done) != TCL_OK) {
        return TCL_ERROR;
    }
    while (!done) {
        int row;
        if (Tcl_GetIntFromObj(widget->interp, key, &row) != TCL_OK ||
            row < 0 || row >= widget->rows ||
            RefreshRow(widget, row) != TCL_OK) {
            Tcl_DictObjDone(&search);
            return TCL_ERROR;
        }
        dirtyRows[row] = 1;
        ++dirtyCount;
        Tcl_DictObjNext(&search, &key, &value, &done);
    }
    Tcl_DictObjDone(&search);
    *dirtyCountPtr = dirtyCount;
    return TCL_OK;
}

static int
ClearDirty(NativeWidget *widget)
{
    Tcl_Obj *method = Tcl_NewStringObj("consumeDirty", -1);
    Tcl_Obj *args[1];
    int result;

    args[0] = method;
    Tcl_IncrRefCount(method);
    result = CallScreen(widget, 1, args);
    Tcl_DecrRefCount(method);
    return result;
}

static void
DrawWidget(NativeWidget *widget, const unsigned char *dirtyRows)
{
    int width;
    int height;
    int row;
    Tcl_Time start;
    Tcl_Time end;
    Display *display;
    Drawable drawable;
    Pixmap pixmap;
    int usePixmap;

    if (widget->tkwin == NULL || !Tk_IsMapped(widget->tkwin)) {
        return;
    }
    width = Tk_Width(widget->tkwin);
    height = Tk_Height(widget->tkwin);
    if (width <= 0 || height <= 0) {
        return;
    }

    Tcl_GetTime(&start);
    display = Tk_Display(widget->tkwin);
    usePixmap = 1;
    pixmap = usePixmap ? Tk_GetPixmap(display, Tk_WindowId(widget->tkwin),
        width, height, Tk_Depth(widget->tkwin)) : None;
    usePixmap = usePixmap && pixmap != None;
    drawable = usePixmap ? pixmap : Tk_WindowId(widget->tkwin);

    if (dirtyRows == NULL) {
        XSetForeground(display, widget->gc, widget->background->pixel);
        XFillRectangle(display, drawable, widget->gc, 0, 0,
            (unsigned int)width, (unsigned int)height);
    } else if (usePixmap) {
        XCopyArea(display, Tk_WindowId(widget->tkwin), pixmap, widget->gc,
            0, 0, (unsigned int)width, (unsigned int)height, 0, 0);
    }

    for (row = 0; row < widget->rows; ++row) {
        int col;
        int y = row * widget->cellHeight;
        Tcl_Time rowStart;
        Tcl_Time rowEnd;
        const char *backgroundRun = NULL;
        int backgroundStart = 0;
        if (dirtyRows != NULL && !dirtyRows[row]) continue;
        Tcl_GetTime(&rowStart);

        if (dirtyRows != NULL) {
            XSetForeground(display, widget->gc, widget->background->pixel);
            XFillRectangle(display, drawable, widget->gc, 0, y,
                (unsigned int)width, (unsigned int)widget->cellHeight);
        }

        for (col = 0; col < widget->cols; ++col) {
            NativeCell *cell = &widget->cells[row * widget->cols + col];

            if (cell->width == 0) continue;

            if (backgroundRun == NULL) {
                backgroundRun = cell->background;
                backgroundStart = col;
            } else if (strcmp(backgroundRun, cell->background) != 0) {
                XColor *color = GetCellColor(widget, backgroundRun,
                    widget->background);
                if (color != NULL) {
                    XSetForeground(display, widget->gc, color->pixel);
                    XFillRectangle(display, drawable, widget->gc,
                        backgroundStart * widget->cellWidth, y,
                        (unsigned int)((col - backgroundStart) *
                            widget->cellWidth),
                        (unsigned int)widget->cellHeight);
                }
                backgroundRun = cell->background;
                backgroundStart = col;
            }
        }

        if (backgroundRun != NULL) {
            XColor *color = GetCellColor(widget, backgroundRun,
                widget->background);
            if (color != NULL) {
                XSetForeground(display, widget->gc, color->pixel);
                XFillRectangle(display, drawable, widget->gc,
                    backgroundStart * widget->cellWidth, y,
                    (unsigned int)((widget->cols - backgroundStart) *
                        widget->cellWidth),
                    (unsigned int)widget->cellHeight);
            }
        }

        {
            const char *foregroundRun = NULL;
            int fontRun = -1;
            int underlineRun = -1;
            int textStart = 0;
            Tcl_DString textRun;
            Tcl_DStringInit(&textRun);

            for (col = 0; col < widget->cols; ++col) {
                NativeCell *cell = &widget->cells[row * widget->cols + col];
                int fontIndex;

                if (cell->width == 0) continue;

                fontIndex = (cell->bold ? 1 : 0) + (cell->italic ? 2 : 0);

                if (foregroundRun == NULL) {
                    foregroundRun = cell->foreground;
                    fontRun = fontIndex;
                    underlineRun = cell->underline;
                    textStart = col;
                } else if (strcmp(foregroundRun, cell->foreground) != 0 ||
                    fontRun != fontIndex ||
                    underlineRun != cell->underline) {
                    XColor *color = GetCellColor(widget, foregroundRun,
                        widget->foreground);
                    if (color != NULL && Tcl_DStringLength(&textRun) > 0) {
                        XSetFont(display, widget->gc,
                            Tk_FontId(widget->fonts[fontRun]));
                        XSetForeground(display, widget->gc, color->pixel);
                        Tk_DrawChars(display, drawable, widget->gc,
                            widget->fonts[fontRun],
                            Tcl_DStringValue(&textRun),
                            Tcl_DStringLength(&textRun),
                            textStart * widget->cellWidth,
                            y + widget->fontAscent[fontRun]);
                        if (underlineRun) {
                            XDrawLine(display, drawable, widget->gc,
                                textStart * widget->cellWidth,
                                y + widget->cellHeight - 2,
                                col * widget->cellWidth - 1,
                                y + widget->cellHeight - 2);
                        }
                    }
                    Tcl_DStringSetLength(&textRun, 0);
                    foregroundRun = cell->foreground;
                    fontRun = fontIndex;
                    underlineRun = cell->underline;
                    textStart = col;
                }
                Tcl_DStringAppend(&textRun, cell->text, -1);
            }

            if (foregroundRun != NULL && Tcl_DStringLength(&textRun) > 0) {
                XColor *color = GetCellColor(widget, foregroundRun,
                    widget->foreground);
                if (color != NULL) {
                    XSetFont(display, widget->gc,
                        Tk_FontId(widget->fonts[fontRun]));
                    XSetForeground(display, widget->gc, color->pixel);
                    Tk_DrawChars(display, drawable, widget->gc,
                        widget->fonts[fontRun], Tcl_DStringValue(&textRun),
                        Tcl_DStringLength(&textRun),
                        textStart * widget->cellWidth,
                        y + widget->fontAscent[fontRun]);
                    if (underlineRun) {
                        XDrawLine(display, drawable, widget->gc,
                            textStart * widget->cellWidth,
                            y + widget->cellHeight - 2,
                            widget->cols * widget->cellWidth - 1,
                            y + widget->cellHeight - 2);
                    }
                }
            }
            Tcl_DStringFree(&textRun);
        }

        Tcl_GetTime(&rowEnd);
        {
            int rowUs = (int)ElapsedMicroseconds(&rowStart, &rowEnd);
            if (rowUs > widget->maxRowUs) widget->maxRowUs = rowUs;
        }
    }

    if (widget->selectionActive) {
        int firstRow = widget->selectionStart / widget->cols;
        int lastRow = widget->selectionEnd / widget->cols;
        XSetFunction(display, widget->invertGc, GXinvert);
        for (row = firstRow; row <= lastRow; ++row) {
            int firstCol;
            int lastCol;
            int col;
            if (dirtyRows != NULL && !dirtyRows[row]) continue;
            firstCol = row == firstRow
                ? widget->selectionStart % widget->cols : 0;
            lastCol = row == lastRow
                ? widget->selectionEnd % widget->cols : widget->cols - 1;
            for (col = firstCol; col <= lastCol; ++col) {
                NativeCell *cell = &widget->cells[row * widget->cols + col];
                if (cell->width == 0) continue;
                XFillRectangle(display, drawable, widget->invertGc,
                    col * widget->cellWidth, row * widget->cellHeight,
                    (unsigned int)(widget->cellWidth *
                        (cell->width == 2 ? 2 : 1)),
                    (unsigned int)widget->cellHeight);
            }
        }
        XSetFunction(display, widget->invertGc, GXcopy);
    }

    if (widget->cursorVisible && widget->cursorBlinkVisible &&
        widget->cursorRow >= 0 && widget->cursorRow < widget->rows &&
        widget->cursorCol >= 0 && widget->cursorCol < widget->cols &&
        (dirtyRows == NULL || dirtyRows[widget->cursorRow])) {
        NativeCell *cell = &widget->cells[
            widget->cursorRow * widget->cols + widget->cursorCol];
        int x = widget->cursorCol * widget->cellWidth;
        int y = widget->cursorRow * widget->cellHeight;
        int cursorWidth = widget->cellWidth * (cell->width == 2 ? 2 : 1);
        int cursorHeight = widget->cellHeight;

        if (widget->cursorShape == 1) {
            y += widget->cellHeight - 2;
            cursorHeight = 2;
        } else if (widget->cursorShape == 2) {
            cursorWidth = 2;
        }

        {
            XColor *cursorForeground = GetCellColor(widget,
                cell->foreground, widget->foreground);
            XColor *cursorBackground = GetCellColor(widget,
                cell->background, widget->background);
            if (cursorForeground != NULL && cursorBackground != NULL) {
                XSetForeground(display, widget->gc,
                    cursorForeground->pixel);
                XFillRectangle(display, drawable, widget->gc, x, y,
                    (unsigned int)cursorWidth, (unsigned int)cursorHeight);
                if (widget->cursorShape == 0 && cell->width > 0) {
                    int fontIndex = (cell->bold ? 1 : 0) +
                        (cell->italic ? 2 : 0);
                    XSetFont(display, widget->gc,
                        Tk_FontId(widget->fonts[fontIndex]));
                    XSetForeground(display, widget->gc,
                        cursorBackground->pixel);
                    Tk_DrawChars(display, drawable, widget->gc,
                        widget->fonts[fontIndex],
                        cell->text, (int)strlen(cell->text), x,
                        widget->cursorRow * widget->cellHeight +
                            widget->fontAscent[fontIndex]);
                }
            }
        }
    }

    if (usePixmap) {
        XCopyArea(display, pixmap, Tk_WindowId(widget->tkwin), widget->gc,
            0, 0, (unsigned int)width, (unsigned int)height, 0, 0);
        Tk_FreePixmap(display, pixmap);
    }
    Tcl_GetTime(&end);
    widget->drawUs += (int)ElapsedMicroseconds(&start, &end);
}

static void
DisplayChanged(ClientData clientData, XEvent *eventPtr)
{
    NativeWidget *widget = (NativeWidget *)clientData;

    if (eventPtr->type == Expose && eventPtr->xexpose.count == 0) {
        DrawWidget(widget, NULL);
    } else if (eventPtr->type == ConfigureNotify) {
        DrawWidget(widget, NULL);
    } else if (eventPtr->type == DestroyNotify) {
        widget->tkwin = NULL;
        if (widget->command != NULL) {
            Tcl_DeleteCommandFromToken(widget->interp, widget->command);
        }
    }
}

static int
ConfigureWidget(NativeWidget *widget, int objc, Tcl_Obj *const objv[])
{
    int i;
    int fontChanged = 0;
    for (i = 0; i < objc; i += 2) {
        const char *option;
        Tcl_Obj *value;
        if (i + 1 >= objc) {
            Tcl_SetObjResult(widget->interp,
                Tcl_NewStringObj("configure option requires a value", -1));
            return TCL_ERROR;
        }
        option = Tcl_GetString(objv[i]);
        value = objv[i + 1];
        if (strcmp(option, "-font") == 0 ||
            strcmp(option, "-boldfont") == 0 ||
            strcmp(option, "-italicfont") == 0 ||
            strcmp(option, "-bolditalicfont") == 0) {
            Tk_Font font = Tk_GetFont(widget->interp, widget->tkwin,
                Tcl_GetString(value));
            if (font == NULL) return TCL_ERROR;
            {
                int slot = strcmp(option, "-font") == 0 ? 0 :
                    (strcmp(option, "-boldfont") == 0 ? 1 :
                    (strcmp(option, "-italicfont") == 0 ? 2 : 3));
                if (widget->fonts[slot] != NULL) Tk_FreeFont(widget->fonts[slot]);
                widget->fonts[slot] = font;
                if (slot == 0) fontChanged = 1;
            }
        } else if (strcmp(option, "-foreground") == 0 ||
                   strcmp(option, "-background") == 0) {
            XColor *color = Tk_GetColor(widget->interp, widget->tkwin,
                Tk_GetUid(Tcl_GetString(value)));
            if (color == NULL) return TCL_ERROR;
            if (strcmp(option, "-foreground") == 0) {
                if (widget->foreground != NULL) Tk_FreeColor(widget->foreground);
                widget->foreground = color;
            } else {
                if (widget->background != NULL) Tk_FreeColor(widget->background);
                widget->background = color;
                Tk_SetWindowBackground(widget->tkwin, color->pixel);
            }
            FreeColors(widget);
        } else if (strcmp(option, "-width") == 0) {
            if (Tcl_GetIntFromObj(widget->interp, value,
                    &widget->widthRequest) != TCL_OK) return TCL_ERROR;
        } else if (strcmp(option, "-height") == 0) {
            if (Tcl_GetIntFromObj(widget->interp, value,
                    &widget->heightRequest) != TCL_OK) return TCL_ERROR;
        } else {
            Tcl_SetObjResult(widget->interp,
                Tcl_ObjPrintf("unknown option \"%s\"", option));
            return TCL_ERROR;
        }
    }

    if (fontChanged) {
        Tk_FontMetrics metrics;
        int i;
        for (i = 0; i < 4; ++i) {
            Tk_GetFontMetrics(widget->fonts[i], &metrics);
            widget->fontAscent[i] = metrics.ascent;
        }
        widget->cellWidth = Tk_TextWidth(widget->fonts[0], "M", 1);
        widget->cellHeight = metrics.linespace;
        if (widget->cellWidth < 1) widget->cellWidth = 1;
        if (widget->cellHeight < 1) widget->cellHeight = 1;
    }
    Tk_GeometryRequest(widget->tkwin,
        widget->cols * widget->cellWidth,
        widget->rows * widget->cellHeight);
    Tk_SetInternalBorder(widget->tkwin, 0);
    XGCValues values;
    values.foreground = widget->foreground->pixel;
    if (widget->gc != None) Tk_FreeGC(widget->display, widget->gc);
    widget->gc = Tk_GetGC(widget->tkwin, GCForeground, &values);
    if (widget->invertGc == None) {
        values.function = GXinvert;
        widget->invertGc = Tk_GetGC(widget->tkwin,
            GCFunction | GCForeground, &values);
    }
    if (widget->cells != NULL) {
        DrawWidget(widget, NULL);
    }
    return TCL_OK;
}

static void
ResetStatistics(NativeWidget *widget)
{
    widget->fullRedraws = 0;
    widget->dirtyRenders = 0;
    widget->renderedRows = 0;
    widget->renderedStyleRuns = 0;
    widget->buildUs = 0;
    widget->drawUs = 0;
    widget->maxRowUs = 0;
}

static int
WidgetRowText(NativeWidget *widget, Tcl_Interp *interp, Tcl_Obj *rowObj)
{
    int row;
    int col;
    Tcl_DString text;

    if (Tcl_GetIntFromObj(interp, rowObj, &row) != TCL_OK ||
        row < 0 || row >= widget->rows) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("row out of range", -1));
        return TCL_ERROR;
    }

    Tcl_DStringInit(&text);
    for (col = 0; col < widget->cols; ++col) {
        NativeCell *cell = &widget->cells[row * widget->cols + col];
        if (cell->width > 0) {
            Tcl_DStringAppend(&text, cell->text, -1);
        }
    }
    Tcl_SetObjResult(interp,
        Tcl_NewStringObj(Tcl_DStringValue(&text), Tcl_DStringLength(&text)));
    Tcl_DStringFree(&text);
    return TCL_OK;
}

static int
WidgetSelection(NativeWidget *widget, Tcl_Interp *interp,
    int objc, Tcl_Obj *const objv[])
{
    const char *operation;

    if (objc < 3) {
        Tcl_WrongNumArgs(interp, 2, objv, "clear|set|text ?row col row col?");
        return TCL_ERROR;
    }
    operation = Tcl_GetString(objv[2]);
    if (strcmp(operation, "clear") == 0) {
        if (objc != 3) {
            Tcl_WrongNumArgs(interp, 3, objv, "");
            return TCL_ERROR;
        }
        widget->selectionActive = 0;
        DrawWidget(widget, NULL);
        return TCL_OK;
    }
    if (strcmp(operation, "set") == 0) {
        int startRow;
        int startCol;
        int endRow;
        int endCol;
        int start;
        int end;
        if (objc != 7) {
            Tcl_WrongNumArgs(interp, 3, objv, "startRow startCol endRow endCol");
            return TCL_ERROR;
        }
        if (Tcl_GetIntFromObj(interp, objv[3], &startRow) != TCL_OK ||
            Tcl_GetIntFromObj(interp, objv[4], &startCol) != TCL_OK ||
            Tcl_GetIntFromObj(interp, objv[5], &endRow) != TCL_OK ||
            Tcl_GetIntFromObj(interp, objv[6], &endCol) != TCL_OK) {
            return TCL_ERROR;
        }
        if (startRow < 0 || startRow >= widget->rows ||
            endRow < 0 || endRow >= widget->rows ||
            startCol < 0 || startCol >= widget->cols ||
            endCol < 0 || endCol >= widget->cols) {
            Tcl_SetObjResult(interp,
                Tcl_NewStringObj("selection coordinates are out of range", -1));
            return TCL_ERROR;
        }
        if (widget->cells[startRow * widget->cols + startCol].width == 0 &&
            startCol > 0) --startCol;
        if (widget->cells[endRow * widget->cols + endCol].width == 0 &&
            endCol > 0) --endCol;
        start = startRow * widget->cols + startCol;
        end = endRow * widget->cols + endCol;
        widget->selectionStart = start < end ? start : end;
        widget->selectionEnd = start < end ? end : start;
        widget->selectionActive = 1;
        DrawWidget(widget, NULL);
        return TCL_OK;
    }
    if (strcmp(operation, "text") == 0) {
        Tcl_DString text;
        int firstRow;
        int lastRow;
        int row;
        if (objc != 3) {
            Tcl_WrongNumArgs(interp, 3, objv, "");
            return TCL_ERROR;
        }
        if (!widget->selectionActive) {
            Tcl_ResetResult(interp);
            return TCL_OK;
        }
        firstRow = widget->selectionStart / widget->cols;
        lastRow = widget->selectionEnd / widget->cols;
        Tcl_DStringInit(&text);
        for (row = firstRow; row <= lastRow; ++row) {
            int firstCol = row == firstRow
                ? widget->selectionStart % widget->cols : 0;
            int lastCol = row == lastRow
                ? widget->selectionEnd % widget->cols : widget->cols - 1;
            int col;
            if (row != firstRow) Tcl_DStringAppend(&text, "\n", 1);
            for (col = firstCol; col <= lastCol; ++col) {
                NativeCell *cell = &widget->cells[row * widget->cols + col];
                if (cell->width > 0) {
                    Tcl_DStringAppend(&text, cell->text, -1);
                }
            }
        }
        Tcl_SetObjResult(interp,
            Tcl_NewStringObj(Tcl_DStringValue(&text), Tcl_DStringLength(&text)));
        Tcl_DStringFree(&text);
        return TCL_OK;
    }
    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
        "unknown selection operation \"%s\"", operation));
    return TCL_ERROR;
}

static int
WidgetCommand(ClientData clientData, Tcl_Interp *interp,
    int objc, Tcl_Obj *const objv[])
{
    NativeWidget *widget = (NativeWidget *)clientData;
    const char *subcommand;

    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv,
            "cget|configure|render|renderDirty|updateCursor|cellSize|cursorBlink|selection|rowText|statistics|resetStatistics");
        return TCL_ERROR;
    }
    subcommand = Tcl_GetString(objv[1]);

    if (strcmp(subcommand, "cget") == 0) {
        const char *option;
        if (objc != 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "option");
            return TCL_ERROR;
        }
        option = Tcl_GetString(objv[2]);
        if (strcmp(option, "-font") == 0 ||
            strcmp(option, "-boldfont") == 0 ||
            strcmp(option, "-italicfont") == 0 ||
            strcmp(option, "-bolditalicfont") == 0) {
            int slot = strcmp(option, "-font") == 0 ? 0 :
                (strcmp(option, "-boldfont") == 0 ? 1 :
                (strcmp(option, "-italicfont") == 0 ? 2 : 3));
            Tcl_SetObjResult(interp,
                Tcl_NewStringObj(Tk_NameOfFont(widget->fonts[slot]), -1));
        } else if (strcmp(option, "-foreground") == 0) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(Tk_NameOfColor(widget->foreground), -1));
        } else if (strcmp(option, "-background") == 0) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(Tk_NameOfColor(widget->background), -1));
        } else if (strcmp(option, "-width") == 0) {
            Tcl_SetObjResult(interp, Tcl_NewIntObj(widget->widthRequest));
        } else if (strcmp(option, "-height") == 0) {
            Tcl_SetObjResult(interp, Tcl_NewIntObj(widget->heightRequest));
        } else {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("unknown option \"%s\"", option));
            return TCL_ERROR;
        }
        return TCL_OK;
    }

    if (strcmp(subcommand, "configure") == 0) {
        if (objc == 2) return TCL_OK;
        if ((objc - 2) % 2 != 0) {
            Tcl_WrongNumArgs(interp, 2, objv, "?option value ...?");
            return TCL_ERROR;
        }
        return ConfigureWidget(widget, objc - 2, objv + 2);
    }

    if (strcmp(subcommand, "render") == 0 ||
        strcmp(subcommand, "renderDirty") == 0) {
        int row;
        int dirtyCount = 0;
        unsigned char *dirtyRows = NULL;
        int previousCursorRow = widget->cursorRow;
        int oldRows = widget->rows;
        int oldCols = widget->cols;
        int dimensionsChanged;
        if (objc != 2) {
            Tcl_WrongNumArgs(interp, 2, objv, "");
            return TCL_ERROR;
        }

        if (GetScreenDimensions(widget) != TCL_OK) return TCL_ERROR;
        if (strcmp(subcommand, "renderDirty") == 0) {
            ++widget->dirtyRenders;
        }
        dimensionsChanged = oldRows != widget->rows || oldCols != widget->cols;
        if (widget->cells != NULL && dimensionsChanged) {
            FreeCells(widget);
        }
        if (dimensionsChanged) {
            widget->selectionActive = 0;
        }
        if (dimensionsChanged) {
            Tk_GeometryRequest(widget->tkwin,
                widget->cols * widget->cellWidth,
                widget->rows * widget->cellHeight);
        }
        if (widget->cells == NULL) {
            widget->cells = (NativeCell *)ckalloc(
                sizeof(NativeCell) * widget->rows * widget->cols);
            widget->cellCount = widget->rows * widget->cols;
            memset(widget->cells, 0,
                sizeof(NativeCell) * (size_t)widget->cellCount);
        }

        if (dimensionsChanged &&
            strcmp(subcommand, "renderDirty") == 0) {
            for (row = 0; row < widget->rows; ++row) {
                if (RefreshRow(widget, row) != TCL_OK) return TCL_ERROR;
            }
            if (ClearDirty(widget) != TCL_OK) return TCL_ERROR;
            if (RefreshCursor(widget) != TCL_OK) return TCL_ERROR;
            ++widget->fullRedraws;
            DrawWidget(widget, NULL);
            widget->cursorDirty = 0;
            return TCL_OK;
        }

        if (strcmp(subcommand, "render") == 0) {
            for (row = 0; row < widget->rows; ++row) {
                if (RefreshRow(widget, row) != TCL_OK) return TCL_ERROR;
            }
            if (ClearDirty(widget) != TCL_OK) return TCL_ERROR;
            ++widget->fullRedraws;
        } else {
            dirtyRows = (unsigned char *)ckalloc((size_t)widget->rows);
            memset(dirtyRows, 0, (size_t)widget->rows);
            if (ConsumeDirty(widget, &dirtyCount, dirtyRows) != TCL_OK) {
                ckfree((char *)dirtyRows);
                return TCL_ERROR;
            }
        }

        if (RefreshCursor(widget) != TCL_OK) return TCL_ERROR;
        if (dirtyRows != NULL && widget->cursorDirty) {
            if (previousCursorRow >= 0 && previousCursorRow < widget->rows) {
                dirtyRows[previousCursorRow] = 1;
            }
            if (widget->cursorRow >= 0 && widget->cursorRow < widget->rows) {
                dirtyRows[widget->cursorRow] = 1;
            }
        }
        if (dirtyRows != NULL) {
            int row;
            int needsPaint = widget->cursorDirty || dirtyCount > 0;
            if (needsPaint) DrawWidget(widget, dirtyRows);
            for (row = 0; row < widget->rows; ++row) {
                if (dirtyRows[row]) ++dirtyCount;
            }
            ckfree((char *)dirtyRows);
        } else {
            DrawWidget(widget, NULL);
        }
        widget->cursorDirty = 0;
        Tcl_SetObjResult(interp, Tcl_NewIntObj(dirtyCount));
        return TCL_OK;
    }

    if (strcmp(subcommand, "updateCursor") == 0) {
        unsigned char *dirtyRows;
        int previousCursorRow = widget->cursorRow;
        if (RefreshCursor(widget) != TCL_OK) return TCL_ERROR;
        dirtyRows = (unsigned char *)ckalloc((size_t)widget->rows);
        memset(dirtyRows, 0, (size_t)widget->rows);
        if (previousCursorRow >= 0 && previousCursorRow < widget->rows) {
            dirtyRows[previousCursorRow] = 1;
        }
        if (widget->cursorRow >= 0 && widget->cursorRow < widget->rows) {
            dirtyRows[widget->cursorRow] = 1;
        }
        DrawWidget(widget, dirtyRows);
        ckfree((char *)dirtyRows);
        return TCL_OK;
    }

    if (strcmp(subcommand, "cellSize") == 0) {
        if (objc != 2) {
            Tcl_WrongNumArgs(interp, 2, objv, "");
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, Tcl_NewListObj(2, (Tcl_Obj *[]){
            Tcl_NewIntObj(widget->cellWidth),
            Tcl_NewIntObj(widget->cellHeight)}));
        return TCL_OK;
    }

    if (strcmp(subcommand, "cursorBlink") == 0) {
        unsigned char *dirtyRows;
        int visible;
        if (objc != 3 ||
            Tcl_GetBooleanFromObj(interp, objv[2], &visible) != TCL_OK) {
            Tcl_WrongNumArgs(interp, 2, objv, "visible");
            return TCL_ERROR;
        }
        widget->cursorBlinkVisible = visible;
        dirtyRows = (unsigned char *)ckalloc((size_t)widget->rows);
        memset(dirtyRows, 0, (size_t)widget->rows);
        if (widget->cursorRow >= 0 && widget->cursorRow < widget->rows) {
            dirtyRows[widget->cursorRow] = 1;
        }
        DrawWidget(widget, dirtyRows);
        ckfree((char *)dirtyRows);
        return TCL_OK;
    }

    if (strcmp(subcommand, "selection") == 0) {
        return WidgetSelection(widget, interp, objc, objv);
    }

    if (strcmp(subcommand, "rowText") == 0) {
        if (objc != 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "row");
            return TCL_ERROR;
        }
        return WidgetRowText(widget, interp, objv[2]);
    }

    if (strcmp(subcommand, "statistics") == 0) {
        Tcl_Obj *stats = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("fullRedraws", -1),
            Tcl_NewIntObj(widget->fullRedraws));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("dirtyRenders", -1),
            Tcl_NewIntObj(widget->dirtyRenders));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("styledRows", -1),
            Tcl_NewIntObj(widget->renderedRows));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("styleRuns", -1),
            Tcl_NewIntObj(widget->renderedStyleRuns));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("buildUs", -1),
            Tcl_NewIntObj(widget->buildUs));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("tkUs", -1),
            Tcl_NewIntObj(widget->drawUs));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("maxRowUs", -1),
            Tcl_NewIntObj(widget->maxRowUs));
        Tcl_DictObjPut(interp, stats, Tcl_NewStringObj("cellReplacements", -1),
            Tcl_NewIntObj(0));
        Tcl_SetObjResult(interp, stats);
        return TCL_OK;
    }

    if (strcmp(subcommand, "resetStatistics") == 0) {
        ResetStatistics(widget);
        return TCL_OK;
    }

    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
        "unknown subcommand \"%s\"", subcommand));
    return TCL_ERROR;
}

static void
WidgetCommandDeleted(ClientData clientData)
{
    NativeWidget *widget = (NativeWidget *)clientData;

    widget->command = NULL;
    if (widget->tkwin != NULL) {
        Tk_Window tkwin = widget->tkwin;
        Tk_DeleteEventHandler(tkwin, ExposureMask | StructureNotifyMask,
            DisplayChanged, widget);
        widget->tkwin = NULL;
        Tk_DestroyWindow(tkwin);
    }

    FreeCells(widget);
    FreeColors(widget);
    {
        int i;
        for (i = 0; i < 4; ++i) {
            if (widget->fonts[i] != NULL) Tk_FreeFont(widget->fonts[i]);
        }
    }
    if (widget->foreground != NULL) Tk_FreeColor(widget->foreground);
    if (widget->background != NULL) Tk_FreeColor(widget->background);
    if (widget->gc != None) Tk_FreeGC(widget->display, widget->gc);
    if (widget->invertGc != None) Tk_FreeGC(widget->display, widget->invertGc);
    if (widget->screen != NULL) Tcl_DecrRefCount(widget->screen);
    ckfree((char *)widget);
}

static int
CreateWidget(ClientData clientData, Tcl_Interp *interp,
    int objc, Tcl_Obj *const objv[])
{
    Tk_Window mainWindow;
    Tk_Window tkwin;
    NativeWidget *widget;
    const char *path;

    (void)clientData;
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "path screenObject");
        return TCL_ERROR;
    }
    mainWindow = Tk_MainWindow(interp);
    if (mainWindow == NULL) return TCL_ERROR;
    path = Tcl_GetString(objv[1]);
    tkwin = Tk_CreateWindowFromPath(interp, mainWindow, path, NULL);
    if (tkwin == NULL) return TCL_ERROR;

    widget = (NativeWidget *)ckalloc(sizeof(NativeWidget));
    memset(widget, 0, sizeof(NativeWidget));
    widget->interp = interp;
    widget->tkwin = tkwin;
    widget->display = Tk_Display(tkwin);
    widget->screen = objv[2];
    Tcl_IncrRefCount(widget->screen);
    widget->cursorVisible = 1;
    widget->cursorBlinkVisible = 1;
    widget->cursorShape = 0;
    widget->widthRequest = 80;
    widget->heightRequest = 24;
    widget->foreground = Tk_GetColor(interp, tkwin, Tk_GetUid("#e5e7eb"));
    widget->background = Tk_GetColor(interp, tkwin, Tk_GetUid("#111827"));
    {
        int i;
        for (i = 0; i < 4; ++i) {
            widget->fonts[i] = Tk_GetFont(interp, tkwin, "TkFixedFont");
        }
    }
    if (widget->foreground == NULL || widget->background == NULL ||
        widget->fonts[0] == NULL || widget->fonts[1] == NULL ||
        widget->fonts[2] == NULL || widget->fonts[3] == NULL ||
        GetScreenDimensions(widget) != TCL_OK) {
        Tk_DestroyWindow(tkwin);
        if (widget->command == NULL) {
            widget->tkwin = NULL;
            WidgetCommandDeleted(widget);
        }
        return TCL_ERROR;
    }

    Tk_SetClass(tkwin, "LATermNativeRenderer");
    {
        Tk_FontMetrics metrics;
        int i;
        for (i = 0; i < 4; ++i) {
            Tk_GetFontMetrics(widget->fonts[i], &metrics);
            widget->fontAscent[i] = metrics.ascent;
        }
        widget->cellWidth = Tk_TextWidth(widget->fonts[0], "M", 1);
        widget->cellHeight = metrics.linespace;
        if (widget->cellWidth < 1) widget->cellWidth = 1;
        if (widget->cellHeight < 1) widget->cellHeight = 1;
    }
    Tk_CreateEventHandler(tkwin, ExposureMask | StructureNotifyMask,
        DisplayChanged, widget);
    widget->command = Tcl_CreateObjCommand(interp, path, WidgetCommand,
        widget, WidgetCommandDeleted);
    if (ConfigureWidget(widget, 0, NULL) != TCL_OK) {
        Tk_DestroyWindow(tkwin);
        return TCL_ERROR;
    }

    Tcl_SetObjResult(interp, Tcl_NewStringObj(path, -1));
    return TCL_OK;
}

DLLEXPORT int
Laterm_renderer_Init(Tcl_Interp *interp)
{
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL ||
        Tk_InitStubs(interp, "8.6", 0) == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_FindNamespace(interp, "::LATerm::native", NULL,
            TCL_LEAVE_ERR_MSG) == NULL) {
        if (Tcl_CreateNamespace(interp, "::LATerm::native", NULL, NULL) == NULL) {
            return TCL_ERROR;
        }
    }
    Tcl_CreateObjCommand(interp, "::LATerm::native::create",
        CreateWidget, NULL, NULL);
    return Tcl_PkgProvide(interp, "laterm_renderer", "0.1");
}
