#include <linux/init.h>
#include <linux/module.h>

static int driver_init(void)
{
  printk(KERN_ALERT "Hello, world\n");
  return 0;
}

static void driver_exit(void)
{
  printk(KERN_ALERT "Goodbye, cruel world\n");
}

module_init(driver_init);
module_exit(driver_exit);
MODULE_LICENSE("GPL");
