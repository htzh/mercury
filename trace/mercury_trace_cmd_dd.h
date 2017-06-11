// vim: ts=4 sw=4 expandtab ft=c

// Copyright (C) 1998-2006 The University of Melbourne.
// This file may only be copied under the terms of the GNU Library General
// Public License - see the file COPYING.LIB in the Mercury distribution.

#ifndef MERCURY_TRACE_CMD_DD_H
#define MERCURY_TRACE_CMD_DD_H

#include "mercury_imp.h"
#include "mercury_stack_trace.h" // for MR_ContextPosition

#include "mercury_trace_cmds.h"

extern  MR_TraceCmdFunc     MR_trace_cmd_dd;
extern  MR_TraceCmdFunc     MR_trace_cmd_trust;
extern  MR_TraceCmdFunc     MR_trace_cmd_untrust;
extern  MR_TraceCmdFunc     MR_trace_cmd_trusted;

extern  const char *const   MR_trace_dd_cmd_args[];

#endif  // MERCURY_TRACE_CMD_DD_H
