#include <cstdio>
#include "grid.h"
#include "fields.h"
#include "dns.h"

cdns::cdns(cgrid *gridin, cfields *fieldsin)
{
  std::printf("Creating instance of object dns\n");
  grid   = gridin;
  fields = fieldsin;

  loop = true;

  time      = 0.;
  runtime   = 1000.;
  dt        = 1.;
  iteration = 0;

  const int ifactor = 1000;

  itime    = (int)(ifactor * time);
  iruntime = (int)(ifactor * runtime);
  idt      = (int)(ifactor * dt);
}

cdns::~cdns()
{
  std::printf("Destroying instance of object dns\n");
}

int cdns::timestep()
{
  time  += dt;
  itime += idt;

  iteration++;

  if(time >= runtime)
    loop = false;

  if(iteration % 100 == 0) 
    std::printf("Iteration = %6d, time = %7.1f\n", iteration, time);

  return 0;
}